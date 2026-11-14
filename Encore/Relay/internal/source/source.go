// Package source reads a remote file over HTTP ranges, refusing to talk to private addresses.
package source

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type HTTP struct {
	client  *http.Client
	url     string // after redirects
	headers map[string]string
	Size    int64
	Type    string
}

var ErrBlocked = errors.New("that address is not allowed")

// Open follows redirects to the file, checks that it supports ranges, and learns its size.
func Open(ctx context.Context, raw string, headers map[string]string, allowPrivate bool) (*HTTP, error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, errors.New("the source must be an http or https address")
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	if !allowPrivate {
		// Checked at connect time, so redirects and DNS answers that point inward are refused too.
		dialer.Control = func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip := net.ParseIP(host)
			if ip == nil || !public(ip) {
				return ErrBlocked
			}
			return nil
		}
	}
	transport := &http.Transport{
		DialContext: dialer.DialContext,
		// HTTP/1.1 on purpose: each parallel range request gets its own connection. Over HTTP/2 they
		// would share one, and a host that limits speed per connection would limit them all together.
		TLSNextProto:          map[string]func(string, *tls.Conn) http.RoundTripper{},
		MaxIdleConnsPerHost:   Parallel + 2,
		MaxConnsPerHost:       Parallel + 2,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		DisableCompression:    true,
	}
	s := &HTTP{client: &http.Client{Transport: transport}, url: raw, headers: headers}
	resp, err := s.get(ctx, 0, 0)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 16))
	s.url = resp.Request.URL.String()
	s.Type = resp.Header.Get("Content-Type")
	if resp.StatusCode != http.StatusPartialContent {
		return nil, fmt.Errorf("the source does not support seeking (HTTP %d)", resp.StatusCode)
	}
	// "bytes 0-0/12345"
	if i := strings.LastIndex(resp.Header.Get("Content-Range"), "/"); i >= 0 {
		s.Size, _ = strconv.ParseInt(resp.Header.Get("Content-Range")[i+1:], 10, 64)
	}
	if s.Size <= 0 {
		return nil, errors.New("the source did not say how large it is")
	}
	return s, nil
}

// URL is where the file really is, after redirects.
func (s *HTTP) URL() string { return s.url }

func (s *HTTP) get(ctx context.Context, from, to int64) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.url, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range s.headers {
		req.Header.Set(k, v)
	}
	// to < 0 reads to the end of the file.
	if to < 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", from))
	} else {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", from, to))
	}
	return s.client.Do(req)
}

// ReadAt returns up to n bytes at off; fewer at the end of the file.
func (s *HTTP) ReadAt(ctx context.Context, off int64, n int) ([]byte, error) {
	if off >= s.Size {
		return nil, nil
	}
	end := off + int64(n) - 1
	if end >= s.Size {
		end = s.Size - 1
	}
	resp, err := s.get(ctx, off, end)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return nil, fmt.Errorf("source answered HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, end-off+1))
}

// Parallel is how many ranged requests a stream keeps in flight. Debrid hosts often cap the speed of
// each connection well below what the server's link can take; several connections add up.
const Parallel = 6

// Stream reads from off to the end of the file, in order, fetching ahead in chunks over several
// connections at once. It fetches only as far ahead as its window: a reader that pauses (the relay
// holds back when it is far ahead of the viewer) pauses the downloads too, with no connection left
// open in the meantime.
func (s *HTTP) Stream(ctx context.Context, off int64) io.ReadCloser {
	ctx, cancel := context.WithCancel(ctx)
	p := &parallel{s: s, ctx: ctx, cancel: cancel, next: off, slots: make(chan struct{}, Parallel)}
	return p
}

type chunk struct {
	done chan struct{}
	data []byte
	err  error
}

type parallel struct {
	s      *HTTP
	ctx    context.Context
	cancel context.CancelFunc
	next   int64    // where the next chunk to schedule starts
	queue  []*chunk // scheduled, in file order
	cur    []byte   // what's left of the chunk being read
	slots  chan struct{}
	count  int
	err    error
}

// chunkSize starts small, so the first segment's few megabytes arrive over all connections at once,
// then grows so later chunks cost fewer requests.
func (p *parallel) chunkSize() int64 {
	if p.count < Parallel*2 {
		return 1 << 20
	}
	return 4 << 20
}

// fill schedules chunks until the window is full or the file ends.
func (p *parallel) fill() {
	for p.next < p.s.Size {
		select {
		case p.slots <- struct{}{}:
		default:
			return
		}
		from := p.next
		to := from + p.chunkSize() - 1
		if to >= p.s.Size {
			to = p.s.Size - 1
		}
		p.next = to + 1
		p.count++
		c := &chunk{done: make(chan struct{})}
		p.queue = append(p.queue, c)
		go p.fetch(c, from, to)
	}
}

func (p *parallel) fetch(c *chunk, from, to int64) {
	defer close(c.done)
	want := int(to - from + 1)
	for attempt := 0; ; attempt++ {
		data, err := p.s.ReadAt(p.ctx, from, want)
		if err == nil && len(data) == want {
			c.data = data
			return
		}
		if err == nil {
			// A short answer: carry on from where it stopped.
			c.data = append(c.data, data...)
			from += int64(len(data))
			want -= len(data)
			continue
		}
		if p.ctx.Err() != nil || attempt >= 3 {
			c.err = err
			return
		}
		select {
		case <-time.After(time.Duration(attempt+1) * 400 * time.Millisecond):
		case <-p.ctx.Done():
			c.err = p.ctx.Err()
			return
		}
	}
}

func (p *parallel) Read(b []byte) (int, error) {
	for len(p.cur) == 0 {
		if p.err != nil {
			return 0, p.err
		}
		p.fill()
		if len(p.queue) == 0 {
			return 0, io.EOF
		}
		c := p.queue[0]
		select {
		case <-c.done:
		case <-p.ctx.Done():
			return 0, p.ctx.Err()
		}
		p.queue = p.queue[1:]
		<-p.slots
		if c.err != nil {
			p.err = c.err
			return 0, c.err
		}
		p.cur = c.data
	}
	n := copy(b, p.cur)
	p.cur = p.cur[n:]
	p.fill()
	return n, nil
}

func (p *parallel) Close() error {
	p.cancel()
	return nil
}

// Speed measures the source from here: how long the first byte takes, and the throughput of one
// connection and of several in parallel, each over a few megabytes from the middle of the file.
type Speed struct {
	FirstByteMs     int64   `json:"firstByteMs"`
	OneConnMbps     float64 `json:"oneConnectionMbps"`
	ParallelMbps    float64 `json:"parallelMbps"`
	ParallelStreams int     `json:"parallelConnections"`
}

func (s *HTTP) Measure(ctx context.Context) Speed {
	var sp Speed
	const size = 6 << 20
	if s.Size < 4*size {
		return sp
	}
	began := time.Now()
	if _, err := s.ReadAt(ctx, s.Size/3, 1); err == nil {
		sp.FirstByteMs = time.Since(began).Milliseconds()
	}
	began = time.Now()
	if b, err := s.ReadAt(ctx, s.Size/3, size); err == nil {
		sp.OneConnMbps = mbps(len(b), time.Since(began))
	}
	began = time.Now()
	stream := s.Stream(ctx, s.Size/2)
	n, _ := io.CopyN(io.Discard, stream, 3*size)
	stream.Close()
	sp.ParallelMbps = mbps(int(n), time.Since(began))
	sp.ParallelStreams = Parallel
	return sp
}

func mbps(bytes int, took time.Duration) float64 {
	if took <= 0 {
		return 0
	}
	return float64(int(float64(bytes)*8/took.Seconds()/1e5)) / 10
}

func public(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() {
		return false
	}
	if v4 := ip.To4(); v4 != nil {
		// Carrier-grade NAT (100.64.0.0/10, also Tailscale) and the benchmarking range.
		if v4[0] == 100 && v4[1]&0xC0 == 64 || v4[0] == 198 && (v4[1] == 18 || v4[1] == 19) || v4[0] == 0 {
			return false
		}
	}
	return true
}
