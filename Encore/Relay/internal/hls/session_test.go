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

func TestPlanCutsOnKeyframesAtLeastFourSecondsApart(t *testing.T) {
	s, file := open(t)
	p := s.Plan
	// Keyframes at 12.2 and 13, and 44 and 45: the second of each pair is too close to start a segment.
	want := []float64{0, 7, 12.2, 19, 26, 31.5, 38, 44, 52, 58.5}
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
	for n := 0; n <= 6; n++ {
		if _, _, err := a.Segment(context.Background(), n); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range []int{6, 3} { // forward past everything, then back
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
