package hls

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"encore/relay/internal/mkv"
)

// Source is the remote file.
type Source interface {
	Stream(ctx context.Context, off int64) io.ReadCloser
}

// Audio says which audio track to carry and whether it can be passed through untouched.
type Audio struct {
	Index int  // among the file's audio tracks
	Copy  bool // the viewer's browser plays this codec as it is
}

// tsOffset is added to every timestamp so none is negative (B-frames decode before they show). It
// is the same for every run, so segments made by different runs line up exactly.
const tsOffset = 10.0

const (
	videoPID = 0x100
	audioPID = 0x101
	// How far ahead of the viewer a run may get before it is held back.
	aheadSegments = 24
	// A run already writing the segment before a wanted one reaches it about as soon as a new run would
	// (a new run's first segment costs one ranged read and ffmpeg's start); further back, a new run wins.
	nearSegments = 1
	keepBehind   = 30
	keepAhead    = 60
)

// Session is one viewer's stream of one file.
type Session struct {
	ID      string
	Plan    Plan
	File    *mkv.File
	audio   Audio
	src     Source
	dir     string
	ffmpeg  string
	created time.Time
	onReady func(time.Duration) // first segment of a run, for stats

	mu       sync.Mutex
	notify   chan struct{}
	done     map[int]bool
	live     map[int]*live // segments being written right now
	runs     []*run
	playhead int
	lastUse  time.Time
	closed   bool
	failure  error // why the latest run that failed did
}

type run struct {
	first  int
	cur    int // segment being written; first until the first boundary is seen
	cancel context.CancelFunc
	dead   bool
	err    error
	// The segment that was being written when ffmpeg's output ended.
	lastPart  string
	lastIndex int
	lastLive  *live
}

// live is a segment while it is being written. Readers follow it as it grows, so a player receives
// the start of a segment while the rest is still being made.
type live struct {
	path  string
	mu    sync.Mutex
	size  int64
	state int // 0 writing, 1 complete, 2 abandoned
	pulse chan struct{}
}

func (l *live) advance(n int) {
	l.mu.Lock()
	l.size += int64(n)
	close(l.pulse)
	l.pulse = make(chan struct{})
	l.mu.Unlock()
}

func (l *live) finish(complete bool) {
	l.mu.Lock()
	if l.state == 0 {
		if complete {
			l.state = 1
		} else {
			l.state = 2
		}
		close(l.pulse)
		l.pulse = make(chan struct{})
	}
	l.mu.Unlock()
}

type liveWriter struct {
	f *os.File
	l *live
}

func (w liveWriter) Write(p []byte) (int, error) {
	n, err := w.f.Write(p)
	if n > 0 {
		w.l.advance(n)
	}
	return n, err
}

// ErrAbandoned: the segment a reader was following will not be finished (the viewer seeked away).
var ErrAbandoned = errors.New("the segment was abandoned")

// follower reads a live segment from its start, waiting for more as it is written.
type follower struct {
	ctx context.Context
	f   *os.File
	l   *live
	off int64
}

func (r *follower) Read(p []byte) (int, error) {
	for {
		n, err := r.f.Read(p)
		if n > 0 {
			r.off += int64(n)
			return n, nil
		}
		if err != nil && err != io.EOF {
			return 0, err
		}
		r.l.mu.Lock()
		state, size, pulse := r.l.state, r.l.size, r.l.pulse
		r.l.mu.Unlock()
		if r.off < size {
			continue // written since the read
		}
		switch state {
		case 1:
			return 0, io.EOF
		case 2:
			return 0, ErrAbandoned
		}
		select {
		case <-pulse:
		case <-r.ctx.Done():
			return 0, r.ctx.Err()
		}
	}
}

func (r *follower) Close() error { return r.f.Close() }

// Reader is a segment to send: a finished file (Path), or one still being written (Live).
type Reader struct {
	Path string
	Live io.ReadCloser
}

func NewSession(id string, f *mkv.File, src Source, audio Audio, dir, ffmpeg string) (*Session, error) {
	plan := NewPlan(f)
	if plan.Count() < 1 {
		return nil, mkv.ErrNoIndex
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Session{ID: id, Plan: plan, File: f, audio: audio, src: src, dir: dir, ffmpeg: ffmpeg,
		created: time.Now(), notify: make(chan struct{}), done: map[int]bool{}, live: map[int]*live{}, lastUse: time.Now()}, nil
}

func (s *Session) path(n int) string { return filepath.Join(s.dir, fmt.Sprintf("seg-%05d.ts", n)) }

func (s *Session) broadcast() {
	close(s.notify)
	s.notify = make(chan struct{})
}

// wait releases the lock until something changes. Call with the lock held.
func (s *Session) wait(ctx context.Context, limit time.Duration) error {
	ch := s.notify
	s.mu.Unlock()
	defer s.mu.Lock()
	t := time.NewTimer(limit)
	defer t.Stop()
	select {
	case <-ch:
		return nil
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Warm starts making the stream at a segment, before the player asks for it.
func (s *Session) Warm(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if n < 0 || n >= s.Plan.Count() || s.closed || s.done[n] {
		return
	}
	s.playhead = n
	if s.runFor(n) == nil {
		s.startRun(n)
	}
}

// Open returns segment n as soon as its first bytes exist, making it if needed, and how long that
// took. A segment still being written is followed as it grows.
func (s *Session) Open(ctx context.Context, n int) (*Reader, time.Duration, error) {
	if n < 0 || n >= s.Plan.Count() {
		return nil, 0, os.ErrNotExist
	}
	began := time.Now()
	wait, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.playhead = n
	s.lastUse = time.Now()
	s.broadcast() // runs held back for being too far ahead look again
	starts := 0
	for {
		if s.closed {
			return nil, 0, errors.New("the stream was closed")
		}
		if s.done[n] {
			return &Reader{Path: s.path(n)}, time.Since(began), nil
		}
		if l := s.live[n]; l != nil {
			if f, err := os.Open(l.path); err == nil {
				return &Reader{Live: &follower{ctx: ctx, f: f, l: l}}, time.Since(began), nil
			}
		}
		if s.runFor(n) == nil {
			if starts >= 3 {
				return nil, 0, fmt.Errorf("the stream could not be prepared: %w", s.lastError())
			}
			starts++
			s.startRun(n)
		}
		if err := s.wait(wait, 5*time.Second); err != nil {
			return nil, 0, err
		}
	}
}

// Segment returns the finished file holding segment n, and how long it took to finish.
func (s *Session) Segment(ctx context.Context, n int) (string, time.Duration, error) {
	began := time.Now()
	for attempt := 0; ; attempt++ {
		r, _, err := s.Open(ctx, n)
		if err != nil {
			return "", 0, err
		}
		if r.Live == nil {
			return r.Path, time.Since(began), nil
		}
		_, err = io.Copy(io.Discard, r.Live)
		r.Live.Close()
		if err != nil && (err != ErrAbandoned || attempt >= 3) {
			return "", 0, err
		}
	}
}

func (s *Session) lastError() error {
	if s.failure != nil {
		return s.failure
	}
	return errors.New("no segment was produced")
}

// runFor is a live run that is writing n or about to.
func (s *Session) runFor(n int) *run {
	for _, r := range s.runs {
		if !r.dead && r.cur <= n && n-r.cur <= nearSegments {
			return r
		}
	}
	return nil
}

// startRun stops any other run first: debrid hosts slow a file down sharply when it is read over two
// connections at once, so a seek must not leave the old position still downloading beside the new.
func (s *Session) startRun(n int) {
	kept := s.runs[:0]
	for _, old := range s.runs {
		if !old.dead {
			old.cancel()
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &run{first: n, cur: n, cancel: cancel}
	s.runs = append(kept, r)
	go s.work(ctx, r)
}

func (s *Session) work(ctx context.Context, r *run) {
	began := time.Now()
	err := s.remux(ctx, r, began)
	cancelled := ctx.Err() != nil
	r.cancel()
	s.mu.Lock()
	r.dead = true
	if err != nil && !cancelled {
		r.err = err
		s.failure = err
	}
	s.broadcast()
	s.mu.Unlock()
}

func (s *Session) remux(ctx context.Context, r *run, began time.Time) error {
	args := []string{"-hide_banner", "-loglevel", "error",
		"-probesize", "1000000", "-analyzeduration", "1000000",
		"-f", "matroska", "-copyts", "-i", "pipe:0",
		"-map", "0:v:0", "-map", fmt.Sprintf("0:a:%d?", s.audio.Index),
		"-c:v", "copy"}
	if s.audio.Copy {
		args = append(args, "-c:a", "copy")
	} else {
		args = append(args, "-c:a", "aac", "-ac", "2", "-b:a", "160k")
	}
	args = append(args, "-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
		"-avoid_negative_ts", "disabled", "-output_ts_offset", fmt.Sprintf("%g", tsOffset),
		"-muxdelay", "0", "-muxpreload", "0",
		"-mpegts_flags", "+pat_pmt_at_frames", "-f", "mpegts", "pipe:1")
	cmd := exec.CommandContext(ctx, s.ffmpeg, args...)
	cmd.WaitDelay = 2 * time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &limited{b: &stderr, n: 4096}
	if err := cmd.Start(); err != nil {
		return err
	}
	body := s.src.Stream(ctx, s.Plan.Offsets[r.first])
	reachedEnd := make(chan bool, 1)
	go func() {
		defer stdin.Close()
		defer body.Close()
		if _, err := stdin.Write(s.File.Header); err != nil {
			reachedEnd <- false
			return
		}
		_, err := io.Copy(stdin, body)
		reachedEnd <- err == nil
	}()
	splitErr := s.split(ctx, r, stdout, began)
	if splitErr != nil {
		r.cancel()
	}
	waitErr := cmd.Wait()
	// The file ended cleanly: whatever was being written is the last segment, complete.
	ended := splitErr == nil && waitErr == nil && <-reachedEnd
	s.finishLast(r, ended)
	if splitErr == errStop {
		return nil
	}
	if splitErr != nil {
		return splitErr
	}
	if waitErr != nil {
		return fmt.Errorf("ffmpeg: %v: %s", waitErr, bytes.TrimSpace(stderr.Bytes()))
	}
	return nil
}

var errStop = errors.New("stop")

// split reads the transport stream and cuts it at the planned keyframes.
func (s *Session) split(ctx context.Context, r *run, stdout io.Reader, began time.Time) error {
	in := bufio.NewReaderSize(stdout, 256<<10)
	var pkt [188]byte
	var pat, pmt []byte // the latest tables, to start each segment with
	var pending [][]byte
	var out *bufio.Writer
	var file *os.File
	var lv *live
	cur := -1
	audioStarted := false
	first := true

	closeCurrent := func(complete bool) error {
		if file == nil {
			return nil
		}
		err := out.Flush()
		if cerr := file.Close(); err == nil {
			err = cerr
		}
		part, l := file.Name(), lv
		file, out, lv = nil, nil, nil
		complete = complete && err == nil
		if complete {
			if err = os.Rename(part, s.path(cur)); err != nil {
				complete = false
			}
		}
		s.mu.Lock()
		if s.live[cur] == l {
			delete(s.live, cur)
		}
		if complete {
			s.done[cur] = true
			s.evict()
		}
		s.broadcast()
		s.mu.Unlock()
		l.finish(complete)
		if !complete {
			os.Remove(part)
			return err
		}
		if first {
			first = false
			if s.onReady != nil {
				s.onReady(time.Since(began))
			}
		}
		return nil
	}
	defer closeCurrent(false)

	for {
		if _, err := io.ReadFull(in, pkt[:]); err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				// Left for remux to decide whether the file really ended here.
				if file != nil {
					r.lastPart, r.lastIndex, r.lastLive = file.Name(), cur, lv
					out.Flush()
					file.Close()
					file, out, lv = nil, nil, nil
				}
				return nil
			}
			return err
		}
		if pkt[0] != 0x47 {
			return errors.New("lost sync in the transport stream")
		}
		pid := int(pkt[1]&0x1F)<<8 | int(pkt[2])
		start := pkt[1]&0x40 != 0
		if pid == 0 || pid == 0x1000 {
			copyOf := append([]byte(nil), pkt[:]...)
			if pid == 0 {
				pat = copyOf
			} else {
				pmt = copyOf
			}
			pending = append(pending, copyOf)
			if len(pending) > 8 {
				pending = pending[len(pending)-8:]
			}
			continue
		}
		if pid == videoPID && start && randomAccess(pkt[:]) {
			if pts, ok := pesPTS(pkt[:]); ok {
				if idx := s.Plan.boundary(pts - tsOffset); idx >= 0 && idx != cur {
					if err := closeCurrent(true); err != nil {
						return err
					}
					// Held back while far ahead of the viewer; stopped where another run already went.
					stop, err := s.admit(ctx, r, idx)
					if err != nil {
						return err
					}
					if stop {
						return errStop
					}
					cur = idx
					f, err := os.Create(s.path(idx) + fmt.Sprintf(".%d.part", r.first))
					if err != nil {
						return err
					}
					lv = &live{path: f.Name(), pulse: make(chan struct{})}
					file, out = f, bufio.NewWriterSize(liveWriter{f, lv}, 32<<10)
					s.mu.Lock()
					s.live[idx] = lv
					s.broadcast()
					s.mu.Unlock()
					audioStarted = false
					// Every segment opens with the tables, so it plays on its own.
					if len(pending) == 0 && pat != nil && pmt != nil {
						pending = [][]byte{pat, pmt}
					}
				}
			}
		}
		if file == nil {
			pending = pending[:0]
			continue
		}
		for _, p := range pending {
			out.Write(p)
		}
		pending = pending[:0]
		if pid == audioPID && !audioStarted {
			if !start {
				continue // the tail of an audio packet that began before this segment
			}
			audioStarted = true
		}
		if _, err := out.Write(pkt[:]); err != nil {
			return err
		}
	}
}

// admit is called as a run reaches segment idx. It waits while the run is too far ahead, and reports
// stop when the segment already exists.
func (s *Session) admit(ctx context.Context, r *run, idx int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r.cur = idx
	waited := time.Now()
	for {
		if s.closed || ctx.Err() != nil {
			return true, nil
		}
		if s.done[idx] {
			return true, nil
		}
		if idx <= s.playhead+aheadSegments {
			return false, nil
		}
		// Nobody has come for a long time: let go of the connection; a later request starts afresh.
		if time.Since(waited) > 90*time.Second {
			return true, nil
		}
		if err := s.wait(ctx, 10*time.Second); err != nil {
			return true, nil
		}
	}
}

// finishLast settles the segment that was being written when ffmpeg's output ended.
func (s *Session) finishLast(r *run, complete bool) {
	if r.lastPart == "" {
		return
	}
	if complete && os.Rename(r.lastPart, s.path(r.lastIndex)) != nil {
		complete = false
	}
	s.mu.Lock()
	if s.live[r.lastIndex] == r.lastLive {
		delete(s.live, r.lastIndex)
	}
	if complete {
		s.done[r.lastIndex] = true
	}
	s.broadcast()
	s.mu.Unlock()
	r.lastLive.finish(complete)
	if !complete {
		os.Remove(r.lastPart)
	}
	r.lastPart = ""
}

// evict drops segments far from the viewer. Call with the lock held.
func (s *Session) evict() {
	for n := range s.done {
		if n < s.playhead-keepBehind || n > s.playhead+keepAhead {
			delete(s.done, n)
			os.Remove(s.path(n))
		}
	}
}

func (s *Session) Idle() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.lastUse)
}

// Runs is how many runs are working, for stats.
func (s *Session) Runs() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, r := range s.runs {
		if !r.dead {
			n++
		}
	}
	return n
}

func (s *Session) OnFirstSegment(fn func(time.Duration)) { s.onReady = fn }

func (s *Session) Close() {
	s.mu.Lock()
	s.closed = true
	for _, r := range s.runs {
		r.cancel()
	}
	s.broadcast()
	s.mu.Unlock()
	os.RemoveAll(s.dir)
}

func randomAccess(p []byte) bool {
	return p[3]&0x20 != 0 && p[4] > 0 && p[5]&0x40 != 0
}

// pesPTS reads the presentation time, in seconds, of a packet that starts a PES packet.
func pesPTS(p []byte) (float64, bool) {
	at := 4
	if p[3]&0x20 != 0 {
		at += 1 + int(p[4])
	}
	if p[3]&0x10 == 0 || at+14 > len(p) {
		return 0, false
	}
	b := p[at:]
	if b[0] != 0 || b[1] != 0 || b[2] != 1 || b[7]&0x80 == 0 {
		return 0, false
	}
	v := int64(b[9]>>1&7)<<30 | int64(b[10])<<22 | int64(b[11]>>1)<<15 | int64(b[12])<<7 | int64(b[13]>>1)
	return float64(v) / 90000, true
}

type limited struct {
	b *bytes.Buffer
	n int
}

func (l *limited) Write(p []byte) (int, error) {
	if room := l.n - l.b.Len(); room > 0 {
		if len(p) > room {
			l.b.Write(p[:room])
		} else {
			l.b.Write(p)
		}
	}
	return len(p), nil
}

func abs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}
