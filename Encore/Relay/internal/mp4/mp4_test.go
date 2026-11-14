package mp4

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

type file struct{ b []byte }

func (f file) ReadAt(_ context.Context, off int64, n int) ([]byte, error) {
	if off >= int64(len(f.b)) {
		return nil, nil
	}
	end := off + int64(n)
	if end > int64(len(f.b)) {
		end = int64(len(f.b))
	}
	return f.b[off:end], nil
}

func make(t *testing.T, args ...string) []byte {
	t.Helper()
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	out := filepath.Join(t.TempDir(), "a.mp4")
	base := []string{"-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "6"}
	if msg, err := exec.Command("ffmpeg", append(append(base, args...), out)...).CombinedOutput(); err != nil {
		t.Fatal(err, string(msg))
	}
	b, _ := os.ReadFile(out)
	return b
}

func TestCodecsFromMoovAtTheEndOrTheStart(t *testing.T) {
	cases := []struct {
		args         []string
		video, audio string
		profile      int
	}{
		{[]string{"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"}, "h264", "aac", 66},
		{[]string{"-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-pix_fmt", "yuv420p", "-c:a", "ac3", "-movflags", "+faststart"}, "h264", "ac3", 100},
		{[]string{"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-c:a", "eac3"}, "h264", "eac3", 110},
		{[]string{"-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-c:a", "aac"}, "hevc", "aac", 0},
	}
	for _, c := range cases {
		b := make(t, c.args...)
		f, err := Parse(context.Background(), file{b}, int64(len(b)))
		if err != nil {
			t.Fatalf("%v: %v", c.args, err)
		}
		var video, audio Track
		for _, tr := range f.Tracks {
			switch tr.Kind {
			case "video":
				video = tr
			case "audio":
				audio = tr
			}
		}
		if video.Codec != c.video || audio.Codec != c.audio || (c.profile != 0 && video.Profile != c.profile) {
			t.Fatalf("%v: got video %+v audio %+v", c.args, video, audio)
		}
		if f.Duration < 5.9 || f.Duration > 6.2 {
			t.Fatalf("duration %.2f", f.Duration)
		}
	}
	if _, err := Parse(context.Background(), file{[]byte("not an mp4 at all, really")}, 25); err != ErrNotMP4 {
		t.Fatal("a text file passed as MP4")
	}
}
