package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const secret = "0123456789abcdef0123456789abcdef"

func TestTokens(t *testing.T) {
	now := time.Now()
	good := signToken(secret, "lab", now.Add(time.Hour))
	if !verifyToken(secret, good, now) {
		t.Fatal("a fresh token was refused")
	}
	if verifyToken(secret, good, now.Add(2*time.Hour)) {
		t.Fatal("an expired token was accepted")
	}
	if verifyToken("another-secret-another-secret-00", good, now) || verifyToken(secret, good+"x", now) || verifyToken(secret, "", now) {
		t.Fatal("a forged token was accepted")
	}
	// The expiry cannot be edited without breaking the signature.
	payload, sig, _ := strings.Cut(good, ".")
	if verifyToken(secret, payload[:len(payload)-2]+"zz."+sig, now) {
		t.Fatal("a tampered token was accepted")
	}
}

func post(t *testing.T, h http.Handler, path, token string, body any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, bytes.NewReader(raw))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestTheAPIEndToEnd(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	dir := t.TempDir()
	make := func(name string, args ...string) {
		base := []string{"-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "12"}
		if out, err := exec.Command("ffmpeg", append(append(base, args...), filepath.Join(dir, name))...).CombinedOutput(); err != nil {
			t.Fatal(err, string(out))
		}
	}
	x264 := []string{"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "48"}
	make("avc-ac3.mkv", append(x264, "-c:a", "ac3")...)
	make("avc-aac.mp4", append(x264, "-c:a", "aac", "-movflags", "+faststart")...)
	make("hevc.mkv", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error", "-c:a", "aac")
	os.WriteFile(filepath.Join(dir, "notes.txt"), bytes.Repeat([]byte("hello "), 100), 0o644)
	files := httptest.NewServer(http.FileServer(http.Dir(dir)))
	defer files.Close()

	relay := NewRelay(Config{Secret: secret, LabCode: "K7QM-2XPD", CacheDir: t.TempDir(), AllowPrivate: true, FFmpeg: "ffmpeg", FFprobe: "ffprobe"})
	defer relay.Close()
	h := relay.Handler()

	// No token, no stream.
	if code, _ := post(t, h, "/v1/session", "", map[string]string{"url": files.URL + "/avc-ac3.mkv"}); code != 401 {
		t.Fatalf("without a token: %d", code)
	}
	// The lab code is forgiving about case and dashes, and wrong guesses run out.
	code, body := post(t, h, "/v1/lab/token", "", map[string]string{"code": "k7qm 2xpd"})
	token, _ := body["token"].(string)
	if code != 200 || token == "" {
		t.Fatalf("lab code: %d %v", code, body)
	}
	for i := 0; i < 8; i++ {
		post(t, h, "/v1/lab/token", "", map[string]string{"code": "nope"})
	}
	if code, _ := post(t, h, "/v1/lab/token", "", map[string]string{"code": "K7QM-2XPD"}); code != 429 {
		t.Fatalf("after many wrong guesses: %d", code)
	}

	// MKV with H.264: repackaged, audio converted unless the browser decodes Dolby itself.
	_, d := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/avc-ac3.mkv", "caps": map[string]any{"video": []string{"h264"}, "audio": []string{"aac"}}})
	if d["mode"] != "remux" || d["audioCopied"] == true {
		t.Fatalf("mkv decision: %v", d)
	}
	_, dolby := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/avc-ac3.mkv", "caps": map[string]any{"video": []string{"h264"}, "audio": []string{"aac", "ac3"}}})
	if dolby["audioCopied"] != true {
		t.Fatalf("Dolby passthrough: %v", dolby)
	}
	// MP4 with H.264 and AAC: the browser plays it straight from the source.
	_, mp4 := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/avc-aac.mp4"})
	if mp4["mode"] != "direct" || mp4["url"] != files.URL+"/avc-aac.mp4" {
		t.Fatalf("mp4 decision: %v", mp4)
	}
	// HEVC and things that aren't video: choose another source.
	if _, hevc := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/hevc.mkv"}); hevc["mode"] != "unsupported" || hevc["reason"] != "hevc" {
		t.Fatalf("hevc decision: %v", hevc)
	}
	if _, txt := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/notes.txt"}); txt["mode"] != "unsupported" {
		t.Fatalf("text decision: %v", txt)
	}

	// The playlist and a segment are served by unguessable id, with browser access allowed.
	get := func(path string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec
	}
	list := get(d["playlist"].(string))
	if list.Code != 200 || !strings.Contains(list.Body.String(), "#EXT-X-ENDLIST") || list.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("playlist: %d %s", list.Code, list.Body.String())
	}
	seg := get(strings.Replace(d["playlist"].(string), "index.m3u8", "seg/1.ts", 1))
	if seg.Code != 200 || seg.Body.Len() < 188 || seg.Body.Bytes()[0] != 0x47 || !strings.HasPrefix(seg.Header().Get("Server-Timing"), "prepare;dur=") {
		t.Fatalf("segment: %d, %d bytes", seg.Code, seg.Body.Len())
	}
	if get("/v1/s/00000000000000000000000000000000/index.m3u8").Code != 404 {
		t.Fatal("an unknown stream was served")
	}
	if get(strings.Replace(d["playlist"].(string), "index.m3u8", "seg/999.ts", 1)).Code != 404 {
		t.Fatal("a segment past the end was served")
	}
	if page := get("/lab"); page.Code != 200 || !strings.Contains(page.Body.String(), "Encore Relay Lab") {
		t.Fatal("the lab page is missing")
	}
}
