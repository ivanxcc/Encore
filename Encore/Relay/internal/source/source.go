// Package source reads a remote file over HTTP ranges, refusing to talk to private addresses.
package source

import (
	"context"
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
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConnsPerHost:   4,
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

// Stream reads from off to the end of the file. A dropped connection is reopened where it stopped,
// so a paused reader (the relay holds back when it is far ahead of the viewer) can carry on later.
func (s *HTTP) Stream(ctx context.Context, off int64) io.ReadCloser {
	return &stream{s: s, ctx: ctx, off: off}
}

type stream struct {
	s       *HTTP
	ctx     context.Context
	off     int64
	body    io.ReadCloser
	retries int
}

func (r *stream) Read(p []byte) (int, error) {
	for {
		if r.off >= r.s.Size {
			return 0, io.EOF
		}
		if r.body == nil {
			resp, err := r.s.get(r.ctx, r.off, -1)
			if err != nil {
				if r.ctx.Err() != nil || r.retries >= 4 {
					return 0, err
				}
				r.retries++
				select {
				case <-time.After(time.Duration(r.retries) * 300 * time.Millisecond):
				case <-r.ctx.Done():
					return 0, r.ctx.Err()
				}
				continue
			}
			if resp.StatusCode != http.StatusPartialContent {
				resp.Body.Close()
				return 0, fmt.Errorf("source answered HTTP %d", resp.StatusCode)
			}
			r.body = resp.Body
		}
		n, err := r.body.Read(p)
		r.off += int64(n)
		if n > 0 {
			r.retries = 0
			return n, nil
		}
		if err == nil {
			continue
		}
		r.body.Close()
		r.body = nil
		if err == io.EOF && r.off >= r.s.Size {
			return 0, io.EOF
		}
		if r.ctx.Err() != nil {
			return 0, r.ctx.Err()
		}
		if r.retries >= 4 {
			return 0, err
		}
		r.retries++
	}
}

func (r *stream) Close() error {
	if r.body != nil {
		return r.body.Close()
	}
	return nil
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
