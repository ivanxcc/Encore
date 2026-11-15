package hls

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"encore/relay/internal/mkv"
	"encore/relay/internal/source"
)

var sample string // a generated MKV: H.264 with B-frames and irregular keyframes, 5.1 AC-3 audio

func TestMain(m *testing.M) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		fmt.Println("ffmpeg not installed; skipping")
		os.Exit(0)
	}
	dir, _ := os.MkdirTemp("", "relay-test")
	sample = filepath.Join(dir, "sample.mkv")
	out, err := exec.Command("ffmpeg", "-v", "error", "-y",
		"-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24000/1001",
		"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
		"-t", "64", "-c:v", "libx264", "-preset", "ultrafast", "-bf", "2", "-pix_fmt", "yuv420p",
		"-force_key_frames", "0,2.5,7,12.2,13,19,26,31.5,38,44,45,52,58.5,61",
		"-x264-params", "keyint=400:scenecut=0",
		"-c:a", "ac3", "-ac", "6", "-b:a", "384k", sample).CombinedOutput()
	if err != nil {
		fmt.Println("could not make the sample:", err, string(out))
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func serve(t *testing.T) *source.HTTP {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, sample)
	}))
	t.Cleanup(server.Close)
	src, err := source.Open(context.Background(), server.URL+"/sample.mkv", nil, true)
	if err != nil {
		t.Fatal(err)
	}
	return src
}

func open(t *testing.T) (*Session, *mkv.File) {
	t.Helper()
	src := serve(t)
	file, err := mkv.Parse(context.Background(), src)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSession("t", file, src, Audio{Index: 0}, t.TempDir(), "ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s, file
}

// videoPTS lists a file's video frame times, sorted.
func videoPTS(t *testing.T, path string) []float64 {
	t.Helper()
	out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "packet=pts_time", "-of", "csv=p=0", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	var pts []float64
	for _, line := range strings.Fields(string(out)) {
		if v, err := strconv.ParseFloat(strings.TrimRight(line, ","), 64); err == nil {
			pts = append(pts, v)
		}
	}
	sort.Float64s(pts)
	return pts
}

func TestIndexMatchesTheFilesKeyframes(t *testing.T) {
	_, file := open(t)
	out, _ := exec.Command("ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", sample).Output()
	var keys []float64
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.Split(line, ",")
		if len(parts) >= 2 && strings.HasPrefix(parts[1], "K") {
			v, _ := strconv.ParseFloat(parts[0], 64)
			keys = append(keys, v)
		}
	}
	sort.Float64s(keys)
	if len(file.Cues) != len(keys) {
		t.Fatalf("index has %d keyframes, the file has %d", len(file.Cues), len(keys))
	}
	for i := range keys {
		if d := file.Cues[i].Time - keys[i]; d > 0.002 || d < -0.002 {
			t.Fatalf("keyframe %d: index says %.3f, file says %.3f", i, file.Cues[i].Time, keys[i])
		}
	}
	if v := file.Video(); v == nil || v.CodecID != "V_MPEG4/ISO/AVC" || v.Width != 640 {
		t.Fatalf("video track: %+v", v)
	}
	if a := file.Of(mkv.TrackAudio); len(a) != 1 || a[0].CodecID != "A_AC3" || a[0].Channels != 6 {
		t.Fatalf("audio tracks: %+v", a)
	}
}

func TestPlanCutsOnKeyframesAtLeastTwoSecondsApart(t *testing.T) {
	s, file := open(t)
	p := s.Plan
	// Keyframes at 12.2 and 13, and 44 and 45: the second of each pair is too close to start a segment.
	want := []float64{0, 2.5, 7, 12.2, 19, 26, 31.5, 38, 44, 52, 58.5, 61}
	if len(p.Starts) != len(want) {
		t.Fatalf("segments start at %v", p.Starts)
	}
	for i := range want {
		if d := p.Starts[i] - want[i]; d > 0.05 || d < -0.05 {
			t.Fatalf("segment %d starts at %.3f, want about %.1f", i, p.Starts[i], want[i])
		}
	}
	total := 0.0
	for i := range p.Starts {
		total += p.Length(i)
	}
	if d := total - file.Duration; d > 0.01 || d < -0.01 {
		t.Fatalf("playlist is %.3f s long, the file is %.3f", total, file.Duration)
	}
	if list := p.Playlist(); !strings.Contains(list, "#EXT-X-ENDLIST") || strings.Count(list, "#EXTINF") != len(want) {
		t.Fatal(list)
	}
}

// Played straight through, the segments hold every frame of the file exactly once, at its own time.
func TestStraightThroughKeepsEveryFrame(t *testing.T) {
	s, _ := open(t)
	source := videoPTS(t, sample)
	var got []float64
	for n := 0; n < s.Plan.Count(); n++ {
		path, _, err := s.Segment(context.Background(), n)
		if err != nil {
			t.Fatalf("segment %d: %v", n, err)
		}
		pts := videoPTS(t, path)
		if len(pts) == 0 {
			t.Fatalf("segment %d has no video", n)
		}
		// A segment's first frame in time is its keyframe, at the planned start.
		if d := pts[0] - tsOffset - s.Plan.Starts[n]; d > 0.012 || d < -0.012 {
			t.Fatalf("segment %d starts at %.3f, planned %.3f", n, pts[0]-tsOffset, s.Plan.Starts[n])
		}
		got = append(got, pts...)
	}
	sort.Float64s(got)
	if len(got) != len(source) {
		t.Fatalf("%d frames in the segments, %d in the file", len(got), len(source))
	}
	for i := range source {
		if d := got[i] - tsOffset - source[i]; d > 0.002 || d < -0.002 {
			t.Fatalf("frame %d is at %.3f, the file has it at %.3f", i, got[i]-tsOffset, source[i])
		}
	}
}

// A segment made by seeking straight to it is the same as the one made by playing up to it.
func TestSeekMakesTheSameSegment(t *testing.T) {
	a, _ := open(t)
	b, _ := open(t)
	for n := 0; n <= 8; n++ {
		if _, _, err := a.Segment(context.Background(), n); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range []int{8, 4} { // forward past everything, then back
		seekPath, took, err := b.Segment(context.Background(), n)
		if err != nil {
			t.Fatalf("seek to %d: %v", n, err)
		}
		playPath, _, _ := a.Segment(context.Background(), n)
		seek, play := videoPTS(t, seekPath), videoPTS(t, playPath)
		if len(seek) != len(play) {
			t.Fatalf("segment %d: %d frames by seeking, %d by playing", n, len(seek), len(play))
		}
		for i := range seek {
			if d := seek[i] - play[i]; d > 0.001 || d < -0.001 {
				t.Fatalf("segment %d frame %d: %.3f by seeking, %.3f by playing", n, i, seek[i], play[i])
			}
		}
		t.Logf("seek to segment %d took %v", n, took.Round(time.Millisecond))
	}
}

// Every segment plays on its own: it has the stream tables, video that starts on a keyframe, and audio.
func TestSegmentsStandAlone(t *testing.T) {
	s, _ := open(t)
	path, _, err := s.Segment(context.Background(), 4)
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("ffprobe", "-v", "error", "-show_entries", "stream=codec_name,channels",
		"-of", "csv=p=0", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	if text := string(out); !strings.Contains(text, "h264") || !strings.Contains(text, "aac,2") {
		t.Fatalf("streams: %q", text)
	}
	// It decodes from its first packet with no errors.
	if msg, err := exec.Command("ffmpeg", "-v", "error", "-i", path, "-f", "null", "-").CombinedOutput(); err != nil || len(msg) > 0 {
		t.Fatalf("decode: %v %s", err, msg)
	}
	data, _ := os.ReadFile(path)
	if len(data)%188 != 0 || data[0] != 0x47 || int(data[1]&0x1F)<<8|int(data[2]) != 0 {
		t.Fatal("a segment must be whole packets and begin with the program table")
	}
}

// The last segment ends with the file.
func TestLastSegmentCompletes(t *testing.T) {
	s, _ := open(t)
	last := s.Plan.Count() - 1
	path, _, err := s.Segment(context.Background(), last)
	if err != nil {
		t.Fatal(err)
	}
	pts := videoPTS(t, path)
	if span := pts[len(pts)-1] - pts[0]; span < s.Plan.Length(last)-0.2 {
		t.Fatalf("last segment spans %.2f s of %.2f", span, s.Plan.Length(last))
	}
}

// Audio is continuous across segments of one run: no gap or overlap longer than a frame.
func TestAudioIsContinuousAcrossSegments(t *testing.T) {
	s, _ := open(t)
	var all []float64
	for n := 0; n < 4; n++ {
		path, _, err := s.Segment(context.Background(), n)
		if err != nil {
			t.Fatal(err)
		}
		out, _ := exec.Command("ffprobe", "-v", "error", "-select_streams", "a:0",
			"-show_entries", "packet=pts_time", "-of", "csv=p=0", path).Output()
		for _, line := range strings.Fields(string(out)) {
			if v, err := strconv.ParseFloat(strings.TrimRight(line, ","), 64); err == nil {
				all = append(all, v)
			}
		}
	}
	frame := 1024.0 / 48000
	for i := 1; i < len(all); i++ {
		if d := all[i] - all[i-1]; d < frame*0.5 || d > frame*1.5 {
			t.Fatalf("audio jumps %.4f s at %.3f", d, all[i])
		}
	}
}

var _ = io.EOF

// A seek leaves at most one run reading the file: the one for the new position.
func TestSeekStopsTheOldRun(t *testing.T) {
	s, _ := open(t)
	if _, _, err := s.Segment(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	for _, n := range []int{6, 2, 9} {
		if _, _, err := s.Segment(context.Background(), n); err != nil {
			t.Fatal(err)
		}
		if runs := s.Runs(); runs > 1 {
			t.Fatalf("%d runs reading the file after seeking to %d, want at most 1", runs, n)
		}
	}
}

// slowSource feeds the file at a fixed rate, like a real network, so "while it is being made" is visible.
type slowSource struct {
	inner Source
	rate  int // bytes per second
}

type slowReader struct {
	io.ReadCloser
	rate int
}

func (r slowReader) Read(p []byte) (int, error) {
	if len(p) > 16<<10 {
		p = p[:16<<10]
	}
	n, err := r.ReadCloser.Read(p)
	time.Sleep(time.Duration(n) * time.Second / time.Duration(r.rate))
	return n, err
}

func (s slowSource) Stream(ctx context.Context, off int64) io.ReadCloser {
	return slowReader{s.inner.Stream(ctx, off), s.rate}
}

// A segment is sent while it is being written: its first bytes arrive well before it is finished,
// and what a follower reads is exactly the finished segment.
func TestSegmentIsServedWhileBeingMade(t *testing.T) {
	src := serve(t)
	file, err := mkv.Parse(context.Background(), src)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSession("live", file, slowSource{src, 400 << 10}, Audio{Index: 0}, t.TempDir(), "ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	began := time.Now()
	r, _, err := s.Open(context.Background(), 3)
	if err != nil {
		t.Fatal(err)
	}
	if r.Live == nil {
		t.Fatal("expected a segment still being written")
	}
	first := make([]byte, 188)
	if _, err := io.ReadFull(r.Live, first); err != nil {
		t.Fatal(err)
	}
	firstByte := time.Since(began)
	rest, err := io.ReadAll(r.Live)
	r.Live.Close()
	if err != nil {
		t.Fatal(err)
	}
	whole := time.Since(began)
	path, _, err := s.Segment(context.Background(), 3)
	if err != nil {
		t.Fatal(err)
	}
	final, _ := os.ReadFile(path)
	if got := append(first, rest...); len(got) != len(final) || string(got) != string(final) {
		t.Fatalf("followed %d bytes, the finished segment is %d", len(got), len(final))
	}
	t.Logf("first bytes after %v, whole segment after %v", firstByte.Round(time.Millisecond), whole.Round(time.Millisecond))
	if firstByte > whole*2/3 {
		t.Fatalf("first bytes (%v) should arrive well before the segment is finished (%v)", firstByte, whole)
	}
}

// A follower of a segment that is abandoned (the viewer seeks away) is told, not left with half a segment.
func TestAbandonedSegmentEndsItsFollowers(t *testing.T) {
	src := serve(t)
	file, _ := mkv.Parse(context.Background(), src)
	s, err := NewSession("gone", file, slowSource{src, 150 << 10}, Audio{Index: 0}, t.TempDir(), "ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	r, _, err := s.Open(context.Background(), 1)
	if err != nil || r.Live == nil {
		t.Fatal(err, r)
	}
	defer r.Live.Close()
	go func() {
		time.Sleep(150 * time.Millisecond)
		s.Warm(9) // a seek far away stops the run that was writing segment 1
	}()
	if _, err := io.ReadAll(r.Live); err != ErrAbandoned {
		t.Fatalf("the follower ended with %v, want ErrAbandoned", err)
	}
}

// Text subtitles come out of the same pass as the video, on the video's own timeline, from wherever
// a run starts; cues a second run finds again are not repeated.
func TestSubtitlesFollowTheStream(t *testing.T) {
	dir := t.TempDir()
	srt := filepath.Join(dir, "a.srt")
	var b strings.Builder
	stamp := func(s float64) string {
		return fmt.Sprintf("00:%02d:%02d,%03d", int(s)/60, int(s)%60, int((s-float64(int(s)))*1000+0.5))
	}
	for i := 0; i < 30; i++ {
		start := float64(i)*2 + 0.5
		fmt.Fprintf(&b, "%d\n%s --> %s\nLine %d <i>here</i>\n\n", i+1, stamp(start), stamp(start+1.5), i+1)
	}
	os.WriteFile(srt, []byte(b.String()), 0o600)
	withSubs := filepath.Join(dir, "subs.mkv")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-y", "-i", sample, "-i", srt, "-map", "0", "-map", "1",
		"-c", "copy", "-c:s", "srt", "-metadata:s:s:0", "language=spa", withSubs).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.ServeFile(w, r, withSubs) }))
	defer server.Close()
	src, err := source.Open(context.Background(), server.URL+"/subs.mkv", nil, true)
	if err != nil {
		t.Fatal(err)
	}
	file, err := mkv.Parse(context.Background(), src)
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSession("subs", file, src, Audio{Index: 0}, t.TempDir(), "ffmpeg")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	s.SetSubtitles([]int{0})

	// Start in the middle, as after a seek.
	mid := s.Plan.Count() / 2
	if _, _, err := s.Segment(context.Background(), mid); err != nil {
		t.Fatal(err)
	}
	from := s.Plan.Starts[mid]
	deadline := time.Now().Add(10 * time.Second)
	var cues []Cue
	for time.Now().Before(deadline) {
		if cues, _, _ = s.Cues(0, 0); len(cues) > 3 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if len(cues) < 3 {
		t.Fatalf("only %d cues after a seek", len(cues))
	}
	for _, c := range cues {
		n := int((c.Start-0.5)/2) + 1
		if want := fmt.Sprintf("Line %d <i>here</i>", n); c.Text != want || c.End-c.Start < 1.4 || c.Start < from-2.5 {
			t.Fatalf("cue %+v: expected %q from about %.1f s on", c, want, from)
		}
	}
	// Back to the start: the earlier cues are added, none twice.
	if _, _, err := s.Segment(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1500 * time.Millisecond)
	all, total, _ := s.Cues(0, 0)
	seen := map[string]bool{}
	for _, c := range all {
		if seen[c.Text+fmt.Sprint(c.Start)] {
			t.Fatalf("cue %+v twice", c)
		}
		seen[c.Text+fmt.Sprint(c.Start)] = true
	}
	if total <= len(cues) || all[0].Start != cues[0].Start {
		t.Fatalf("after going back: %d cues (had %d)", total, len(cues))
	}
	if newer, n, _ := s.Cues(0, total-1); len(newer) != 1 || n != total {
		t.Fatalf("cues after %d: %d", total-1, len(newer))
	}
}

// A scrub-bar picture comes from the keyframe's own cluster, and is made once.
func TestThumbnail(t *testing.T) {
	s, _ := open(t)
	began := time.Now()
	path, err := s.Thumbnail(context.Background(), 30)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(path)
	if len(raw) < 1000 || raw[0] != 0xFF || raw[1] != 0xD8 {
		t.Fatalf("not a JPEG: %d bytes", len(raw))
	}
	first := time.Since(began)
	began = time.Now()
	if again, err := s.Thumbnail(context.Background(), 30.5); err != nil || again != path {
		t.Fatalf("the same keyframe again: %v %v", again, err)
	}
	t.Logf("first %v, again %v", first.Round(time.Millisecond), time.Since(began).Round(time.Microsecond))
}

// Video the browser can't decode is re-encoded as H.264, with a keyframe exactly at the start of
// every planned segment, from wherever a run starts; seeks give the same frame times as playing.
func TestConvertedSegmentsLineUp(t *testing.T) {
	dir := t.TempDir()
	hevc := filepath.Join(dir, "hevc.mkv")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
		"-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "24", "-c:v", "libx265", "-preset", "ultrafast",
		"-pix_fmt", "yuv420p10le", "-x265-params", "keyint=60:min-keyint=60:scenecut=0:log-level=error",
		"-c:a", "aac", hevc).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.ServeFile(w, r, hevc) }))
	defer server.Close()
	make := func() *Session {
		src, err := source.Open(context.Background(), server.URL+"/hevc.mkv", nil, true)
		if err != nil {
			t.Fatal(err)
		}
		file, err := mkv.Parse(context.Background(), src)
		if err != nil {
			t.Fatal(err)
		}
		s, err := NewSession("c", file, src, Audio{Index: 0, Copy: true}, t.TempDir(), "ffmpeg")
		if err != nil {
			t.Fatal(err)
		}
		s.SetConvert(&Convert{Height: 240})
		t.Cleanup(s.Close)
		return s
	}
	played, seeked := make(), make()
	if played.Plan.Count() < 6 {
		t.Fatalf("plan of %d segments", played.Plan.Count())
	}
	began := time.Now()
	for n := 0; n < played.Plan.Count(); n++ {
		path, _, err := played.Segment(context.Background(), n)
		if err != nil {
			t.Fatalf("segment %d: %v", n, err)
		}
		out, _ := exec.Command("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,height:packet=pts_time,flags",
			"-of", "csv=p=0", path).Output()
		lines := strings.Fields(string(out))
		if len(lines) < 2 || !strings.Contains(string(out), "h264,240") {
			t.Fatalf("segment %d isn't 240p H.264: %s", n, out)
		}
		firstPacket := lines[0]
		if !strings.Contains(firstPacket, "K") {
			t.Fatalf("segment %d doesn't open on a keyframe: %s", n, firstPacket)
		}
		pts, _ := strconv.ParseFloat(strings.Split(firstPacket, ",")[0], 64)
		if d := pts - tsOffset - played.Plan.Starts[n]; d > 0.05 || d < -0.05 {
			t.Fatalf("segment %d starts at %.3f, planned %.3f", n, pts-tsOffset, played.Plan.Starts[n])
		}
	}
	t.Logf("converted %d segments (%.0f s of video) in %v", played.Plan.Count(), played.File.Duration, time.Since(began).Round(time.Millisecond))
	mid := played.Plan.Count() / 2
	seekPath, _, err := seeked.Segment(context.Background(), mid)
	if err != nil {
		t.Fatal(err)
	}
	playPath, _, _ := played.Segment(context.Background(), mid)
	a, b := videoPTS(t, seekPath), videoPTS(t, playPath)
	if len(a) != len(b) || a[0] != b[0] {
		t.Fatalf("segment %d by seeking: %d frames from %.3f; by playing: %d from %.3f", mid, len(a), a[0], len(b), b[0])
	}
}
