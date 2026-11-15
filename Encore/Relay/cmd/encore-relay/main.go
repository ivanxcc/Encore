// encore-relay prepares remote video files for web browsers: it decides whether a browser can play
// a file as it is, and otherwise repackages it (video untouched) into an HLS stream made of
// independent segments. See ../../README.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"encore/relay/internal/source"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "token":
		token(os.Args[2:])
	case "bench":
		bench(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  encore-relay serve              run the relay (configured by RELAY_* environment variables)
  encore-relay token [-ttl 720h]  print an access token signed with RELAY_SECRET
  encore-relay bench -url URL     time preparing and seeking a file from this machine`)
	os.Exit(2)
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	addr := fs.String("addr", env("RELAY_ADDR", "127.0.0.1:8089"), "address to listen on")
	fs.Parse(args)
	cfg := Config{
		Convert:      os.Getenv("RELAY_CONVERT"),
		Secret:       os.Getenv("RELAY_SECRET"),
		LabCode:      os.Getenv("RELAY_LAB_CODE"),
		CacheDir:     env("RELAY_CACHE", os.TempDir()+"/encore-relay"),
		CloudURL:     os.Getenv("ENCORE_CLOUD_URL"),
		AllowPrivate: os.Getenv("RELAY_ALLOW_PRIVATE") == "1",
		FFmpeg:       env("RELAY_FFMPEG", "ffmpeg"),
		FFprobe:      env("RELAY_FFPROBE", "ffprobe"),
		DataDir:      os.Getenv("RELAY_DATA"),
	}
	if len(cfg.Secret) < 24 {
		log.Fatal("RELAY_SECRET must be set to at least 24 random characters")
	}
	if n, err := strconv.Atoi(os.Getenv("RELAY_CONNECTIONS")); err == nil && n >= 1 && n <= 8 {
		source.Connections = n
	}
	os.RemoveAll(cfg.CacheDir) // segments from a previous run are of no use
	relay := NewRelay(cfg)
	server := &http.Server{Addr: *addr, Handler: relay.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		server.Shutdown(ctx)
		relay.Close()
	}()
	log.Printf("encore-relay listening on %s", *addr)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func token(args []string) {
	fs := flag.NewFlagSet("token", flag.ExitOnError)
	ttl := fs.Duration("ttl", 30*24*time.Hour, "how long the token is valid")
	sub := fs.String("sub", "cli", "who the token is for")
	fs.Parse(args)
	secret := os.Getenv("RELAY_SECRET")
	if len(secret) < 24 {
		log.Fatal("RELAY_SECRET must be set")
	}
	fmt.Println(signToken(secret, *sub, time.Now().Add(*ttl)))
}

func bench(args []string) {
	fs := flag.NewFlagSet("bench", flag.ExitOnError)
	url := fs.String("url", "", "the file to test")
	seeks := fs.Int("seeks", 5, "how many random seeks to time")
	private := fs.Bool("private", false, "allow private addresses")
	fs.Parse(args)
	if *url == "" {
		usage()
	}
	dir, _ := os.MkdirTemp("", "relay-bench")
	defer os.RemoveAll(dir)
	relay := NewRelay(Config{CacheDir: dir, AllowPrivate: *private, FFmpeg: "ffmpeg", FFprobe: "ffprobe"})
	defer relay.Close()
	ctx := context.Background()
	began := time.Now()
	d, err := relay.Decide(ctx, Request{URL: *url})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("decision: %s %s (open %d ms, index %d ms, total %v)\n", d.Mode, d.Reason, d.Timings.OpenMs, d.Timings.IndexMs,
		time.Since(began).Round(time.Millisecond))
	if d.Mode != "remux" {
		return
	}
	s := relay.session(d.ID)
	fmt.Printf("stream: %d segments, %.0f s, video %s %dx%d\n", s.Plan.Count(), s.Plan.Duration, d.Video.Codec, d.Video.Width, d.Video.Height)
	_, took, err := s.Segment(ctx, 0)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("first segment: %v\n", took.Round(time.Millisecond))
	_, took, _ = s.Segment(ctx, 1)
	fmt.Printf("next segment (prefetched): %v\n", took.Round(time.Millisecond))
	for i := 0; i < *seeks; i++ {
		n := rand.Intn(s.Plan.Count())
		_, took, err := s.Segment(ctx, n)
		if err != nil {
			fmt.Printf("seek to %.0f s: %v\n", s.Plan.Starts[n], err)
			continue
		}
		fmt.Printf("seek to %5.0f s: %v\n", s.Plan.Starts[n], took.Round(time.Millisecond))
	}
}
