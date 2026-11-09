package source

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
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
