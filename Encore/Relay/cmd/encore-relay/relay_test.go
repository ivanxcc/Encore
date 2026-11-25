package main

import (
	"bytes"
	"encoding/json"
	"fmt"
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
	// HEVC: another source first (it can be converted, when asked for), then converted, one at a time.
	if _, hevc := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/hevc.mkv"}); hevc["mode"] != "unsupported" || hevc["reason"] != "hevc" || hevc["convertible"] != true {
		t.Fatalf("hevc decision: %v", hevc)
	}
	_, converted := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/hevc.mkv", "convert": true})
	if converted["mode"] != "remux" || converted["converted"] != true {
		t.Fatalf("hevc, converted: %v", converted)
	}
	if _, second := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/hevc.mkv", "convert": true}); second["reason"] != "busy" {
		t.Fatalf("a second conversion at once: %v", second)
	}
	// Turned off, nothing is offered for converting.
	off := NewRelay(Config{Secret: secret, CacheDir: t.TempDir(), FFmpeg: "ffmpeg", AllowPrivate: true, Convert: "off"})
	defer off.Close()
	if _, hevc := post(t, off.Handler(), "/v1/session", token, map[string]any{"url": files.URL + "/hevc.mkv", "convert": true}); hevc["mode"] != "unsupported" || hevc["convertible"] == true {
		t.Fatalf("hevc with converting off: %v", hevc)
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

// An account is linked once with the relay's code; after that its sign-in alone gets tokens. Other
// accounts get nothing without the code.
func TestAccountLinking(t *testing.T) {
	stremio := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ AuthKey string }
		json.NewDecoder(r.Body).Decode(&body)
		switch body.AuthKey {
		case "key-ivan":
			w.Write([]byte(`{"result":{"_id":"1","email":"Ivan@Example.com"}}`))
		case "key-other":
			w.Write([]byte(`{"result":{"_id":"2","email":"other@example.com"}}`))
		case "key-third":
			w.Write([]byte(`{"result":{"_id":"3","email":"third@example.com"}}`))
		default:
			w.Write([]byte(`{"error":{"message":"Session does not exist"}}`))
		}
	}))
	defer stremio.Close()
	data := t.TempDir()
	cfg := Config{Secret: secret, LabCode: "K7QM-2XPD", CacheDir: t.TempDir(), DataDir: data, StremioAPI: stremio.URL, FFmpeg: "ffmpeg"}
	relay := NewRelay(cfg)
	h := relay.Handler()

	if code, body := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan"}); code != 403 || body["needsCode"] != true {
		t.Fatalf("an unlinked account: %d %v", code, body)
	}
	if code, _ := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan", "code": "WRONG-ONE"}); code != 403 {
		t.Fatalf("a wrong code: %d", code)
	}
	code, body := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan", "code": "k7qm2xpd"})
	token, _ := body["token"].(string)
	if code != 200 || !verifyToken(secret, token, time.Now()) || body["email"] != "ivan@example.com" {
		t.Fatalf("linking: %d %v", code, body)
	}
	// Linked: no code needed again, on this relay or after a restart.
	if code, _ := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan"}); code != 200 {
		t.Fatalf("a linked account: %d", code)
	}
	relay.Close()
	restarted := NewRelay(cfg)
	defer restarted.Close()
	h = restarted.Handler()
	if code, _ := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan"}); code != 200 {
		t.Fatalf("after a restart: %d", code)
	}
	if code, _ := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-other"}); code != 403 {
		t.Fatalf("another account: %d", code)
	}
	if code, _ := post(t, h, "/v1/auth", "", map[string]string{"authKey": "made-up"}); code != 401 {
		t.Fatalf("a made-up sign-in: %d", code)
	}

	// An invitation lets one more account in, once; it is no access token itself.
	_, body = post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-ivan"})
	token, _ = body["token"].(string)
	if body["admin"] != true {
		t.Fatalf("the account linked with the code manages the relay: %v", body)
	}
	_, body = post(t, h, "/v1/invite", token, nil)
	invite, _ := body["invite"].(string)
	if invite == "" || verifyToken(secret, invite, time.Now()) {
		t.Fatalf("an invitation: %v", body)
	}
	if code, _ := post(t, h, "/v1/session", invite, map[string]string{"url": "http://example.com/a.mkv"}); code != 401 {
		t.Fatalf("an invitation used as a token: %d", code)
	}
	code, body = post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-other", "invite": invite})
	other, _ := body["token"].(string)
	if code != 200 || body["admin"] == true {
		t.Fatalf("joining by invitation: %d %v", code, body)
	}
	if code, body := post(t, h, "/v1/auth", "", map[string]string{"authKey": "key-third", "invite": invite}); code != 403 || !strings.Contains(fmt.Sprint(body["error"]), "already been used") {
		t.Fatalf("an invitation used twice: %d %v", code, body)
	}

	// The manager sees who can use the relay and can take someone off it; their token stops working.
	get := func(path, token string) (int, map[string]any) {
		req := httptest.NewRequest("GET", path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	if code, body := get("/v1/people", token); code != 200 || len(body["people"].([]any)) != 2 {
		t.Fatalf("people: %d %v", code, body)
	}
	if code, _ := get("/v1/people", other); code != 403 {
		t.Fatalf("people, for someone invited: %d", code)
	}
	req := httptest.NewRequest("DELETE", "/v1/people/other@example.com", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("removing: %d", rec.Code)
	}
	if code, _ := get("/v1/stats", other); code != 401 {
		t.Fatalf("a removed account's token: %d", code)
	}
}

// A file seen before is understood without reading its index again, whatever address it comes from.
func TestIndexIsRemembered(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	dir := t.TempDir()
	if out, err := exec.Command("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24", "-t", "40",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "48", filepath.Join(dir, "a.mkv")).CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	inner := http.FileServer(http.Dir(dir))
	files := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.URL.Path = "/a.mkv" // any address, the same file: like a debrid link with a new token each time
		inner.ServeHTTP(w, r)
	}))
	defer files.Close()
	relay := NewRelay(Config{Secret: secret, CacheDir: t.TempDir(), AllowPrivate: true, FFmpeg: "ffmpeg"})
	defer relay.Close()
	token := signToken(secret, "t", time.Now().Add(time.Hour))
	h := relay.Handler()
	_, first := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/token-one/a.mkv"})
	_, second := post(t, h, "/v1/session", token, map[string]any{"url": files.URL + "/token-two/a.mkv"})
	if first["mode"] != "remux" || second["mode"] != "remux" {
		t.Fatalf("decisions: %v / %v", first["mode"], second["mode"])
	}
	relay.mu.Lock()
	recalled := relay.stats.IndexesRecalled
	relay.mu.Unlock()
	if recalled != 1 {
		t.Fatalf("the index was recalled %d times, want 1", recalled)
	}
}

func TestSubtitleFilesAreRead(t *testing.T) {
	srt := "1\r\n00:00:01,500 --> 00:00:03,000\r\n<font color=\"#fff\">Caf\xe9</font> <i>ol\xe9</i>\r\n\r\n2\r\n00:01:02,05 --> 00:01:04,000\r\n{\\an8}Top line\r\n"
	cues := parseSubtitles(decodeText([]byte(srt)))
	if len(cues) != 2 || cues[0].Text != "Café <i>olé</i>" || cues[0].Start != 1.5 || cues[1].Start != 62.05 || cues[1].Text != "Top line" {
		t.Fatalf("SRT in Windows-1252: %+v", cues)
	}
	vtt := "\xEF\xBB\xBFWEBVTT\n\nintro\n01:02.500 --> 01:04.000 align:start\nHello\nthere\n"
	cues = parseSubtitles(decodeText([]byte(vtt)))
	if len(cues) != 1 || cues[0].Start != 62.5 || cues[0].Text != "Hello\nthere" {
		t.Fatalf("WebVTT: %+v", cues)
	}
}

// People who were invited watch; only the people who manage the relay invite, see the people, read
// the counters, or pause someone. Once the relay has an owner, its code links no one new.
func TestMembersCantManage(t *testing.T) {
	stremio := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ AuthKey string }
		json.NewDecoder(r.Body).Decode(&body)
		switch body.AuthKey {
		case "key-owner":
			w.Write([]byte(`{"result":{"email":"owner@example.com"}}`))
		case "key-member":
			w.Write([]byte(`{"result":{"email":"member@example.com"}}`))
		case "key-stranger":
			w.Write([]byte(`{"result":{"email":"stranger@example.com"}}`))
		}
	}))
	defer stremio.Close()
	relay := NewRelay(Config{Secret: secret, LabCode: "K7QM-2XPD", CacheDir: t.TempDir(), DataDir: t.TempDir(), StremioAPI: stremio.URL, FFmpeg: "ffmpeg"})
	defer relay.Close()
	h := relay.Handler()
	call := func(method, path, token string, body any) (int, map[string]any) {
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest(method, path, bytes.NewReader(raw))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}

	// The relay's code works for the first account only.
	_, body := call("POST", "/v1/auth", "", map[string]string{"authKey": "key-owner", "code": "K7QM-2XPD"})
	owner, _ := body["token"].(string)
	if owner == "" || body["admin"] != true {
		t.Fatalf("the owner linking: %v", body)
	}
	if code, body := call("POST", "/v1/auth", "", map[string]string{"authKey": "key-stranger", "code": "K7QM-2XPD"}); code != 403 || !strings.Contains(fmt.Sprint(body["error"]), "invitation") {
		t.Fatalf("a second account with the code: %d %v", code, body)
	}
	if code, _ := call("POST", "/v1/lab/token", "", map[string]string{"code": "K7QM-2XPD"}); code != 403 {
		t.Fatalf("a lab token by code, with an owner: %d", code)
	}
	if code, _ := call("POST", "/v1/lab/token", owner, map[string]string{}); code != 200 {
		t.Fatalf("a lab token for the owner: %d", code)
	}

	_, body = call("POST", "/v1/invite", owner, nil)
	_, body = call("POST", "/v1/auth", "", map[string]string{"authKey": "key-member", "invite": body["invite"].(string)})
	member, _ := body["token"].(string)
	if member == "" || body["admin"] == true {
		t.Fatalf("the member joining: %v", body)
	}
	for _, c := range []struct{ method, path string }{{"POST", "/v1/invite"}, {"GET", "/v1/people"}, {"GET", "/v1/stats"}, {"POST", "/v1/speed"},
		{"PATCH", "/v1/people/owner@example.com"}, {"DELETE", "/v1/people/owner@example.com"}} {
		if code, _ := call(c.method, c.path, member, map[string]any{"paused": true}); code != 403 {
			t.Fatalf("%s %s by a member: %d", c.method, c.path, code)
		}
	}
	if code, _ := call("POST", "/v1/lab/token", member, map[string]string{}); code == 200 {
		t.Fatal("a lab token for a member")
	}

	// Paused: nothing works for them, including signing in again; resumed, everything does.
	if code, _ := call("PATCH", "/v1/people/member@example.com", owner, map[string]any{"paused": true}); code != 200 {
		t.Fatalf("pausing: %d", code)
	}
	if code, body := call("POST", "/v1/session", member, map[string]string{"url": "http://example.com/a.mkv"}); code != 403 || body["paused"] != true {
		t.Fatalf("a session while paused: %d %v", code, body)
	}
	if code, body := call("POST", "/v1/auth", "", map[string]string{"authKey": "key-member"}); code != 403 || body["paused"] != true {
		t.Fatalf("signing in while paused: %d %v", code, body)
	}
	call("PATCH", "/v1/people/member@example.com", owner, map[string]any{"paused": false, "streams": 1})
	if code, _ := call("POST", "/v1/auth", "", map[string]string{"authKey": "key-member"}); code != 200 {
		t.Fatalf("signing in once resumed: %d", code)
	}
	_, body = call("GET", "/v1/people", owner, nil)
	for _, p := range body["people"].([]any) {
		row := p.(map[string]any)
		if row["email"] == "member@example.com" && (row["streams"] != 1.0 || row["convert"] != false || row["paused"] == true) {
			t.Fatalf("the member's row: %v", row)
		}
	}
	if code, _ := call("PATCH", "/v1/people/owner@example.com", owner, map[string]any{"paused": true}); code != 400 {
		t.Fatalf("pausing yourself: %d", code)
	}
	// Converting is for the owner unless allowed; the member's limit is what was set.
	if !relay.mayConvert("owner@example.com") || relay.mayConvert("member@example.com") {
		t.Fatal("who may convert, by default")
	}
	call("PATCH", "/v1/people/member@example.com", owner, map[string]any{"convert": true})
	if limit, _ := relay.streamLimit("member@example.com"); !relay.mayConvert("member@example.com") || limit != 1 {
		t.Fatalf("after allowing: convert %v, limit %d", relay.mayConvert("member@example.com"), limit)
	}
	if limit, _ := relay.streamLimit("owner@example.com"); limit != 0 {
		t.Fatalf("the owner's limit: %d", limit)
	}
}
