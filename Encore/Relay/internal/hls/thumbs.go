package hls

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Thumbnail returns a small picture of the keyframe at or before a moment, for the scrub bar. It is
// made from the start of that keyframe's cluster only (a few hundred kilobytes), one at a time per
// stream so it never crowds the stream itself, and kept for the life of the stream.
func (s *Session) Thumbnail(ctx context.Context, seconds float64) (string, error) {
	n := s.Plan.At(seconds)
	if n < 0 || n >= s.Plan.Count() {
		return "", os.ErrNotExist
	}
	path := filepath.Join(s.dir, fmt.Sprintf("thumb-%05d.jpg", n))
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	// One at a time: a viewer dragging along the bar asks for many; the latest ones are wanted.
	select {
	case s.thumbs <- struct{}{}:
	case <-ctx.Done():
		return "", ctx.Err()
	}
	defer func() { <-s.thumbs }()
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	end := int64(-1)
	if n+1 < s.Plan.Count() {
		end = s.Plan.Offsets[n+1]
	}
	var lastErr error
	for _, limit := range []int64{512 << 10, 2 << 20} {
		if end > 0 && end-s.Plan.Offsets[n] < limit {
			limit = end - s.Plan.Offsets[n]
		}
		picture, err := s.picture(ctx, s.Plan.Offsets[n], limit)
		if err == nil {
			tmp := path + ".tmp"
			if err := os.WriteFile(tmp, picture, 0o600); err != nil {
				return "", err
			}
			return path, os.Rename(tmp, path)
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return "", lastErr
}

func (s *Session) picture(ctx context.Context, offset, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.ffmpeg, "-hide_banner", "-loglevel", "error",
		"-probesize", "500000", "-analyzeduration", "0", "-f", "matroska", "-i", "pipe:0",
		"-map", "0:v:0", "-frames:v", "1", "-vf", "scale=400:-2:flags=bilinear",
		"-q:v", "6", "-f", "image2", "-c:v", "mjpeg", "pipe:1")
	body := s.src.Stream(ctx, offset)
	defer body.Close()
	cmd.Stdin = io.MultiReader(bytes.NewReader(s.File.Header), io.LimitReader(body, limit))
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &limited{b: &stderr, n: 2048}
	if err := cmd.Run(); err != nil || out.Len() == 0 {
		return nil, fmt.Errorf("thumbnail: %v %s", err, bytes.TrimSpace(stderr.Bytes()))
	}
	return out.Bytes(), nil
}
