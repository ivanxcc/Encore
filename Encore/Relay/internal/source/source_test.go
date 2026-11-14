package source

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The relay fetches addresses that viewers give it, so it must never reach into its own network.
func TestPrivateAddressesAreRefused(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "a.mkv", serverTime, strings.NewReader("0123456789"))
	}))
	defer server.Close()
	if _, err := Open(context.Background(), server.URL, nil, false); err == nil {
		t.Fatal("a loopback address was fetched")
	}
	// A public address that redirects inward is refused at the connection too.
	for _, ip := range []string{"127.0.0.1", "10.1.2.3", "192.168.1.1", "169.254.169.254", "100.100.1.1", "::1", "fd00::1", "0.0.0.0"} {
		if public(net.ParseIP(ip)) {
			t.Fatalf("%s counted as public", ip)
		}
	}
	for _, ip := range []string{"1.1.1.1", "8.8.8.8", "2606:4700::1111"} {
		if !public(net.ParseIP(ip)) {
			t.Fatalf("%s counted as private", ip)
		}
	}
	for _, bad := range []string{"file:///etc/passwd", "ftp://x/y", "notaurl"} {
		if _, err := Open(context.Background(), bad, nil, true); err == nil {
			t.Fatalf("%s was accepted", bad)
		}
	}
}

func TestRangesAndResume(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "a.mkv", serverTime, strings.NewReader("0123456789"))
	}))
	defer server.Close()
	s, err := Open(context.Background(), server.URL, nil, true)
	if err != nil || s.Size != 10 {
		t.Fatal(err, s)
	}
	if b, _ := s.ReadAt(context.Background(), 7, 100); string(b) != "789" {
		t.Fatalf("read %q", b)
	}
	body := s.Stream(context.Background(), 4)
	buf := make([]byte, 32)
	var got []byte
	for {
		n, err := body.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			break
		}
	}
	if string(got) != "456789" {
		t.Fatalf("streamed %q", got)
	}
}

var serverTime = time.Unix(1_700_000_000, 0)

// A host that limits each connection (as debrid hosts often do): the stream still delivers the exact
// bytes in order, and several connections together go several times faster than one.
func TestParallelStreamIsExactAndFasterOnThrottledHosts(t *testing.T) {
	data := make([]byte, 12<<20)
	for i := range data {
		data[i] = byte(i*7 + i/4096)
	}
	const perConnection = 4 << 20 // bytes per second: slow enough that the limit, not the CPU, decides
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(&throttled{ResponseWriter: w, rate: perConnection}, r, "big.mkv", serverTime, bytes.NewReader(data))
	}))
	defer server.Close()
	s, err := Open(context.Background(), server.URL, nil, true)
	if err != nil {
		t.Fatal(err)
	}

	began := time.Now()
	stream := s.Stream(context.Background(), 1234567)
	got, err := io.ReadAll(stream)
	stream.Close()
	parallelTook := time.Since(began)
	if err != nil || !bytes.Equal(got, data[1234567:]) {
		t.Fatalf("stream returned %d bytes (err %v), want %d exact bytes", len(got), err, len(data)-1234567)
	}

	began = time.Now()
	one, _ := s.ReadAt(context.Background(), 1234567, len(data)-1234567)
	oneTook := time.Since(began)
	if !bytes.Equal(one, data[1234567:]) {
		t.Fatal("a single read was wrong")
	}
	t.Logf("one connection %v, parallel %v", oneTook.Round(time.Millisecond), parallelTook.Round(time.Millisecond))
	if parallelTook > oneTook*6/10 {
		t.Fatalf("parallel (%v) should be well under one connection (%v)", parallelTook, oneTook)
	}
}

// A stream that's closed early stops fetching.
func TestStreamStopsWhenClosed(t *testing.T) {
	var requests atomic.Int32
	data := make([]byte, 64<<20)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		http.ServeContent(w, r, "big.mkv", serverTime, bytes.NewReader(data))
	}))
	defer server.Close()
	s, _ := Open(context.Background(), server.URL, nil, true)
	stream := s.Stream(context.Background(), 0)
	buf := make([]byte, 1000)
	stream.Read(buf)
	stream.Close()
	time.Sleep(200 * time.Millisecond)
	before := requests.Load()
	time.Sleep(300 * time.Millisecond)
	if after := requests.Load(); after != before || after > int32(Parallel*2+2) {
		t.Fatalf("requests went from %d to %d after closing", before, after)
	}
}

type throttled struct {
	http.ResponseWriter
	rate int
}

func (w *throttled) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		n := len(p)
		if n > 64<<10 {
			n = 64 << 10
		}
		m, err := w.ResponseWriter.Write(p[:n])
		written += m
		if err != nil {
			return written, err
		}
		time.Sleep(time.Duration(float64(n) / float64(w.rate) * float64(time.Second)))
		p = p[n:]
	}
	return written, nil
}
