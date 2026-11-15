package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"encore/relay/internal/hls"
	"encore/relay/internal/mkv"
	"encore/relay/internal/mp4"
	"encore/relay/internal/source"
)

//go:embed lab.html
var labPage []byte

//go:embed hls.min.js
var hlsScript []byte

// The web app (Encore/Web), built into this folder before the relay is compiled.
//
//go:embed all:web
var webFiles embed.FS

type Config struct {
	Secret       string
	LabCode      string
	CacheDir     string
	CloudURL     string
	AllowPrivate bool
	FFmpeg       string
	FFprobe      string // unused: kept so older settings still parse
	// DataDir keeps who may use the relay (owners.json). Empty: remembered until restart only.
	DataDir string
	// StremioAPI is where sign-ins are checked. Empty: api.strem.io.
	StremioAPI string
}

type Relay struct {
	cfg      Config
	mu       sync.Mutex
	sessions map[string]*hls.Session
	attempts map[string][]time.Time // lab-code guesses, per address
	owners   map[string]person      // Stremio accounts (by email) allowed to use this relay
	used     map[string]int64       // invites already taken, until they would have expired
	indexes  map[string]indexed     // files already understood, by size and a hash of their first bytes
	stats    Stats
	stop     chan struct{}
}

type Stats struct {
	Decisions       int     `json:"decisions"`
	Direct          int     `json:"direct"`
	Remux           int     `json:"remux"`
	Unsupported     int     `json:"unsupported"`
	IndexesRecalled int     `json:"indexesRecalled"`
	Segments        int     `json:"segments"`
	Runs            int     `json:"runs"`
	FirstSegmentP   float64 `json:"firstSegmentMsAvg"`
	firstTotal      float64
}

const (
	maxSessions = 8
	idleLimit   = 15 * time.Minute
)

func NewRelay(cfg Config) *Relay {
	r := &Relay{cfg: cfg, sessions: map[string]*hls.Session{}, attempts: map[string][]time.Time{},
		owners: map[string]person{}, used: map[string]int64{}, indexes: map[string]indexed{}, stop: make(chan struct{})}
	r.loadOwners()
	go r.reap()
	return r
}

func (r *Relay) Close() {
	close(r.stop)
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, s := range r.sessions {
		s.Close()
		delete(r.sessions, id)
	}
}

func (r *Relay) reap() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-t.C:
			r.mu.Lock()
			for id, s := range r.sessions {
				if s.Idle() > idleLimit {
					s.Close()
					delete(r.sessions, id)
				}
			}
			r.mu.Unlock()
		}
	}
}

func (r *Relay) session(id string) *hls.Session {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[id]
}

// Request is what a player asks: this file, on a browser that can decode these codecs.
type Request struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	Caps    struct {
		Video []string `json:"video"`
		Audio []string `json:"audio"`
		// Audio the browser plays inside an HLS stream, when that is narrower than what it plays from
		// a file (a script-driven player takes only AAC). Left out, Audio stands for both.
		Stream *[]string `json:"stream,omitempty"`
	} `json:"caps"`
	Start    float64 `json:"start"`    // where playback will begin, in seconds
	Audio    *int    `json:"audio"`    // a chosen audio track
	Language string  `json:"language"` // preferred audio language
}

type TrackInfo struct {
	Index    int    `json:"index"`
	Codec    string `json:"codec"`
	Language string `json:"language,omitempty"`
	Name     string `json:"name,omitempty"`
	Channels int    `json:"channels,omitempty"`
	Default  bool   `json:"default,omitempty"`
	Forced   bool   `json:"forced,omitempty"`
	Text     bool   `json:"text,omitempty"`
}

// Decision is how to play it.
type Decision struct {
	// direct: play URL as it is. remux: play Playlist. unsupported: choose another source.
	Mode     string  `json:"mode"`
	Reason   string  `json:"reason,omitempty"`
	URL      string  `json:"url,omitempty"`
	ID       string  `json:"id,omitempty"`
	Playlist string  `json:"playlist,omitempty"`
	Duration float64 `json:"duration,omitempty"`
	Segments int     `json:"segments,omitempty"`
	Video    struct {
		Codec  string `json:"codec,omitempty"`
		Width  int    `json:"width,omitempty"`
		Height int    `json:"height,omitempty"`
		HDR    bool   `json:"hdr,omitempty"`
	} `json:"video"`
	Audio       *TrackInfo  `json:"audio,omitempty"`
	AudioCopied bool        `json:"audioCopied,omitempty"`
	AudioTracks []TrackInfo `json:"audioTracks,omitempty"`
	Subtitles   []TrackInfo `json:"subtitles,omitempty"`
	Timings     struct {
		OpenMs  int64 `json:"openMs"`
		IndexMs int64 `json:"indexMs"`
	} `json:"timings"`
}

func has(list []string, want string) bool {
	for _, v := range list {
		if strings.EqualFold(v, want) {
			return true
		}
	}
	return false
}

var codecNames = map[string]string{
	"V_MPEG4/ISO/AVC": "h264", "V_MPEGH/ISO/HEVC": "hevc", "V_AV1": "av1", "V_VP9": "vp9", "V_VP8": "vp8",
	"A_AAC": "aac", "A_AC3": "ac3", "A_EAC3": "eac3", "A_DTS": "dts", "A_TRUEHD": "truehd", "A_OPUS": "opus",
	"A_VORBIS": "vorbis", "A_FLAC": "flac", "A_MPEG/L3": "mp3", "A_MPEG/L2": "mp2",
	"S_TEXT/UTF8": "srt", "S_TEXT/ASS": "ass", "S_TEXT/SSA": "ssa", "S_TEXT/WEBVTT": "vtt",
	"S_HDMV/PGS": "pgs", "S_VOBSUB": "vobsub", "S_DVBSUB": "dvbsub",
}

func codecName(id string) string {
	if n, ok := codecNames[id]; ok {
		return n
	}
	if strings.HasPrefix(id, "A_AAC") {
		return "aac"
	}
	if strings.HasPrefix(id, "A_DTS") {
		return "dts"
	}
	if strings.HasPrefix(id, "A_PCM") {
		return "pcm"
	}
	return strings.ToLower(id)
}

// Decide opens the file and chooses how this browser should play it.
func (r *Relay) Decide(ctx context.Context, req Request) (*Decision, error) {
	d := &Decision{}
	began := time.Now()
	src, err := source.Open(ctx, req.URL, req.Headers, r.cfg.AllowPrivate)
	if err != nil {
		return nil, err
	}
	d.Timings.OpenMs = time.Since(began).Milliseconds()
	began = time.Now()
	file, err := r.index(ctx, src)
	d.Timings.IndexMs = time.Since(began).Milliseconds()
	r.count(func(s *Stats) { s.Decisions++ })

	if errors.Is(err, mkv.ErrNotMatroska) {
		d = r.decideOther(ctx, req, src, d)
		d.Timings.IndexMs = time.Since(began).Milliseconds() // reading the MP4's movie box
		return d, nil
	}
	if file == nil {
		return nil, err
	}
	video := file.Video()
	if video == nil {
		return unsupported(r, d, "no-video", "The file has no video track."), nil
	}
	d.Duration = file.Duration
	d.Video.Codec, d.Video.Width, d.Video.Height = codecName(video.CodecID), video.Width, video.Height
	d.Video.HDR = video.Transfer == 16 || video.Transfer == 18
	audio := file.Of(mkv.TrackAudio)
	for i, t := range audio {
		d.AudioTracks = append(d.AudioTracks, TrackInfo{Index: i, Codec: codecName(t.CodecID), Language: t.Language,
			Name: t.Name, Channels: t.Channels, Default: t.Default})
	}
	for i, t := range file.Of(mkv.TrackSubtitle) {
		name := codecName(t.CodecID)
		d.Subtitles = append(d.Subtitles, TrackInfo{Index: i, Codec: name, Language: t.Language, Name: t.Name,
			Default: t.Default, Forced: t.Forced, Text: name == "srt" || name == "ass" || name == "ssa" || name == "vtt"})
	}

	// Video is never re-encoded here: the browser must be able to decode it as it is.
	switch {
	case d.Video.Codec != "h264":
		return unsupported(r, d, d.Video.Codec, "This video needs converting for this browser."), nil
	case len(req.Caps.Video) > 0 && !has(req.Caps.Video, "h264"):
		return unsupported(r, d, "h264", "This browser cannot play H.264."), nil
	case len(video.CodecPrivate) > 1 && !map[byte]bool{66: true, 77: true, 88: true, 100: true}[video.CodecPrivate[1]]:
		return unsupported(r, d, "h264-10bit", "10-bit H.264 needs converting for browsers."), nil
	case d.Video.HDR:
		return unsupported(r, d, "hdr", "HDR video needs converting for this browser."), nil
	}
	if err != nil { // ErrNoIndex
		return unsupported(r, d, "no-index", "The file has no keyframe index."), nil
	}

	choice := hls.Audio{}
	if len(audio) > 0 {
		choice.Index = pickAudio(audio, req)
		name := codecName(audio[choice.Index].CodecID)
		// AAC and MP3 play everywhere; Dolby audio passes through where the browser says it decodes it.
		choice.Copy = name == "aac" || name == "mp3" || (name == "ac3" || name == "eac3") && has(streamAudio(req), name)
		info := d.AudioTracks[choice.Index]
		d.Audio, d.AudioCopied = &info, choice.Copy
	}

	id := randomID()
	session, err := hls.NewSession(id, file, src, choice, filepath.Join(r.cfg.CacheDir, id), r.cfg.FFmpeg)
	if err != nil {
		return unsupported(r, d, "no-index", err.Error()), nil
	}
	// Text subtitles are collected as the stream is made (pictures, like PGS, can't be).
	var texts []int
	for _, t := range d.Subtitles {
		if t.Text && len(texts) < 16 {
			texts = append(texts, t.Index)
		}
	}
	session.SetSubtitles(texts)
	session.OnFirstSegment(func(took time.Duration) {
		r.count(func(s *Stats) {
			s.Runs++
			s.firstTotal += float64(took.Milliseconds())
			s.FirstSegmentP = s.firstTotal / float64(s.Runs)
		})
	})
	r.mu.Lock()
	if len(r.sessions) >= maxSessions {
		r.dropIdlest()
	}
	r.sessions[id] = session
	r.stats.Remux++
	r.mu.Unlock()
	// Start on the segment playback will begin with, before the player has even fetched the playlist.
	session.Warm(session.Plan.At(req.Start))

	d.Mode, d.ID, d.Playlist, d.Segments = "remux", id, "/v1/s/"+id+"/index.m3u8", session.Plan.Count()
	return d, nil
}

type indexed struct {
	file *mkv.File
	err  error
}

// index reads a Matroska file's tracks and keyframe index, or recalls them: a file seen before
// (the same size and first bytes, whatever its address) costs nothing to understand again.
func (r *Relay) index(ctx context.Context, src *source.HTTP) (*mkv.File, error) {
	head := src.Head
	if len(head) > 4096 {
		head = head[:4096]
	}
	sum := sha256.Sum256(head)
	key := fmt.Sprintf("%d:%x", src.Size, sum[:12])
	r.mu.Lock()
	hit, ok := r.indexes[key]
	r.mu.Unlock()
	if ok {
		r.count(func(s *Stats) { s.IndexesRecalled++ })
		return hit.file, hit.err
	}
	file, err := mkv.Parse(ctx, src)
	if err == nil || errors.Is(err, mkv.ErrNoIndex) || errors.Is(err, mkv.ErrNotMatroska) {
		r.mu.Lock()
		if len(r.indexes) >= 400 {
			for k := range r.indexes { // any one: the map is a cache, not a record
				delete(r.indexes, k)
				break
			}
		}
		r.indexes[key] = indexed{file, err}
		r.mu.Unlock()
	}
	return file, err
}

// streamAudio is the audio a browser decodes inside an HLS stream.
func streamAudio(req Request) []string {
	if req.Caps.Stream != nil {
		return *req.Caps.Stream
	}
	return req.Caps.Audio
}

// The three-letter codes files use, for the two-letter ones browsers and settings use.
var threeLetter = map[string]string{"eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it",
	"por": "pt", "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "nob": "no", "dan": "da", "fin": "fi", "pol": "pl",
	"rus": "ru", "ukr": "uk", "tur": "tr", "ara": "ar", "heb": "he", "hin": "hi", "jpn": "ja", "kor": "ko", "chi": "zh",
	"zho": "zh", "vie": "vi", "tha": "th", "ind": "id", "cze": "cs", "ces": "cs", "gre": "el", "ell": "el", "hun": "hu",
	"rum": "ro", "ron": "ro"}

// sameLanguage reduces a language code to two letters ("spa", "es-419" -> "es").
func sameLanguage(code string) string {
	c := strings.ToLower(strings.TrimSpace(code))
	if two, ok := threeLetter[c]; ok {
		return two
	}
	c, _, _ = strings.Cut(c, "-")
	if len(c) >= 2 {
		return c[:2]
	}
	return ""
}

func pickAudio(tracks []mkv.Track, req Request) int {
	if req.Audio != nil && *req.Audio >= 0 && *req.Audio < len(tracks) {
		return *req.Audio
	}
	want := sameLanguage(req.Language)
	if want == "" {
		want = "en"
	}
	// The preferred language's default track, then any track in it, then the file's default.
	best, score := 0, -1
	for i, t := range tracks {
		s := 0
		if sameLanguage(t.Language) == want {
			s += 4
		}
		if t.Default {
			s += 2
		}
		if !strings.Contains(strings.ToLower(t.Name), "commentary") {
			s++
		}
		if s > score {
			best, score = i, s
		}
	}
	return best
}

// decideOther handles files that are not Matroska: an MP4 plays straight from the source when this
// browser decodes its codecs. Its movie box is read directly (one to three ranged reads).
func (r *Relay) decideOther(ctx context.Context, req Request, src *source.HTTP, d *Decision) *Decision {
	file, err := mp4.Parse(ctx, src, src.Size)
	if err != nil {
		return unsupported(r, d, "container", "Only MP4 and Matroska files are supported.")
	}
	d.Duration = file.Duration
	videoOK, audioOK, sawAudio := false, false, false
	for _, t := range file.Tracks {
		switch t.Kind {
		case "video":
			if d.Video.Codec != "" {
				continue
			}
			d.Video.Codec = t.Codec
			switch t.Codec {
			case "h264":
				// 8-bit profiles only: browsers don't decode High 10 and above.
				videoOK = t.Profile == 0 || t.Profile == 66 || t.Profile == 77 || t.Profile == 88 || t.Profile == 100
			default:
				videoOK = has(req.Caps.Video, t.Codec)
			}
		case "audio":
			if !sawAudio {
				sawAudio = true
				audioOK = t.Codec == "aac" || t.Codec == "mp3" || has(req.Caps.Audio, t.Codec)
			}
		}
	}
	if videoOK && (audioOK || !sawAudio) {
		r.count(func(s *Stats) { s.Direct++ })
		d.Mode, d.URL = "direct", req.URL
		return d
	}
	return unsupported(r, d, "mp4-codecs", "This MP4's codecs need converting for this browser.")
}

func unsupported(r *Relay, d *Decision, reason, detail string) *Decision {
	r.count(func(s *Stats) { s.Unsupported++ })
	d.Mode, d.Reason = "unsupported", reason
	_ = detail
	return d
}

func (r *Relay) count(fn func(*Stats)) {
	r.mu.Lock()
	fn(&r.stats)
	r.mu.Unlock()
}

// dropIdlest closes the session nobody has used for longest. Call with the lock held.
func (r *Relay) dropIdlest() {
	type entry struct {
		id   string
		idle time.Duration
	}
	var all []entry
	for id, s := range r.sessions {
		all = append(all, entry{id, s.Idle()})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].idle > all[j].idle })
	if len(all) > 0 {
		r.sessions[all[0].id].Close()
		delete(r.sessions, all[0].id)
	}
}

func randomID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// MARK: Tokens

// signToken makes "payload.signature": who it is for and when it expires, signed with the secret.
func signToken(secret, sub string, expires time.Time) string {
	payload := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%d:%s", expires.Unix(), sub)))
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:16])
}

func verifyToken(secret, token string, now time.Time) bool {
	payload, sig, ok := strings.Cut(token, ".")
	if !ok || secret == "" {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(payload))
	want := base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:16])
	if subtle.ConstantTimeCompare([]byte(sig), []byte(want)) != 1 {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return false
	}
	exp, _, _ := strings.Cut(string(raw), ":")
	unix, err := strconv.ParseInt(exp, 10, 64)
	return err == nil && now.Unix() < unix
}

// MARK: HTTP

func (r *Relay) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"ok": true}) })
	mux.HandleFunc("POST /v1/session", r.authed(r.handleSession))
	mux.HandleFunc("GET /v1/stats", r.authed(r.handleStats))
	mux.HandleFunc("POST /v1/speed", r.authed(r.handleSpeed))
	mux.HandleFunc("GET /v1/s/{id}/index.m3u8", r.handlePlaylist)
	mux.HandleFunc("GET /v1/s/{id}/seg/{file}", r.handleSegment)
	mux.HandleFunc("DELETE /v1/s/{id}", r.handleClose)
	mux.HandleFunc("GET /v1/s/{id}/subs/{track}", r.handleCues)
	mux.HandleFunc("GET /v1/subtitle", r.authed(r.handleSubtitle))
	mux.HandleFunc("POST /v1/lab/token", r.handleLabToken)
	mux.HandleFunc("POST /v1/auth", r.handleAuth)
	mux.HandleFunc("POST /v1/invite", r.authed(r.handleInvite))
	mux.HandleFunc("GET /v1/people", r.authed(r.handlePeople))
	mux.HandleFunc("DELETE /v1/people/{email}", r.authed(r.handleRemovePerson))
	mux.HandleFunc("GET /config.json", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]string{"cloud": strings.TrimRight(r.cfg.CloudURL, "/")})
	})
	mux.HandleFunc("GET /", r.handleApp)
	mux.HandleFunc("GET /lab", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(bytes.Replace(labPage, []byte("__ENCORE_CLOUD_URL__"), []byte(strings.TrimRight(r.cfg.CloudURL, "/")), 1))
	})
	mux.HandleFunc("GET /lab/hls.min.js", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.Write(hlsScript)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		// Any site may call the relay: access is by token and unguessable stream ids, never cookies.
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", "*")
		h.Set("Access-Control-Expose-Headers", "Server-Timing")
		h.Set("Timing-Allow-Origin", "*")
		if req.Method == http.MethodOptions {
			h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "authorization, content-type")
			h.Set("Access-Control-Max-Age", "86400")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		mux.ServeHTTP(w, req)
	})
}

func (r *Relay) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		token := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
		if !verifyToken(r.cfg.Secret, token, time.Now()) || r.removed(tokenSubject(token)) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "A valid token is required."})
			return
		}
		next(w, req)
	}
}

// removed says whether a token was made for an account that has since been taken off the relay.
// Tokens for the lab and the command line (not an email) are not tied to an account.
func (r *Relay) removed(sub string) bool {
	if !strings.Contains(sub, "@") {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.owners[sub]
	return !ok
}

func (r *Relay) handleSession(w http.ResponseWriter, req *http.Request) {
	var body Request
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 64<<10)).Decode(&body); err != nil || body.URL == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected a JSON body with a url."})
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 30*time.Second)
	defer cancel()
	d, err := r.Decide(ctx, body)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// handleSpeed measures a source from the relay: first-byte time, and throughput over one connection
// and over several. It answers "is the server's link to the debrid host the bottleneck?".
func (r *Relay) handleSpeed(w http.ResponseWriter, req *http.Request) {
	var body Request
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 64<<10)).Decode(&body); err != nil || body.URL == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected a JSON body with a url."})
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 60*time.Second)
	defer cancel()
	began := time.Now()
	src, err := source.Open(ctx, body.URL, body.Headers, r.cfg.AllowPrivate)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	opened := time.Since(began).Milliseconds()
	speed := src.Measure(ctx)
	writeJSON(w, 200, map[string]any{"openMs": opened, "speed": speed, "sizeMB": src.Size >> 20})
}

func (r *Relay) handleStats(w http.ResponseWriter, _ *http.Request) {
	r.mu.Lock()
	stats := r.stats
	open := len(r.sessions)
	r.mu.Unlock()
	writeJSON(w, 200, map[string]any{"stats": stats, "openStreams": open})
}

func (r *Relay) handlePlaylist(w http.ResponseWriter, req *http.Request) {
	s := r.session(req.PathValue("id"))
	if s == nil {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Write([]byte(s.Plan.Playlist()))
}

func (r *Relay) handleSegment(w http.ResponseWriter, req *http.Request) {
	s := r.session(req.PathValue("id"))
	n, err := strconv.Atoi(strings.TrimSuffix(req.PathValue("file"), ".ts"))
	if s == nil || err != nil {
		http.NotFound(w, req)
		return
	}
	reader, took, err := s.Open(req.Context(), n)
	if err != nil {
		if req.Context().Err() != nil {
			return // the player moved on
		}
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, req)
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	r.count(func(st *Stats) { st.Segments++ })
	w.Header().Set("Content-Type", "video/mp2t")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("Server-Timing", fmt.Sprintf("prepare;dur=%d", took.Milliseconds()))
	if reader.Live == nil {
		http.ServeFile(w, req, reader.Path)
		return
	}
	// Still being made: send what exists and follow it, so the player gets the start of the segment
	// while the rest is on its way.
	defer reader.Live.Close()
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 64<<10)
	for {
		n, err := reader.Live.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err == io.EOF {
			return
		}
		if err != nil {
			// Abandoned mid-way: break the connection so the player knows the segment is incomplete.
			panic(http.ErrAbortHandler)
		}
	}
}

// handleCues gives a subtitle track's cues found so far; the player asks again for the ones after
// those it has, every few seconds.
func (r *Relay) handleCues(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	s := r.sessions[req.PathValue("id")]
	r.mu.Unlock()
	track, err1 := strconv.Atoi(req.PathValue("track"))
	after, _ := strconv.Atoi(req.URL.Query().Get("after"))
	if s == nil || err1 != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No such stream."})
		return
	}
	cues, total, ok := s.Cues(track, after)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No such subtitle track."})
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, map[string]any{"cues": cues, "total": total})
}

func (r *Relay) handleClose(w http.ResponseWriter, req *http.Request) {
	id := req.PathValue("id")
	r.mu.Lock()
	if s := r.sessions[id]; s != nil {
		s.Close()
		delete(r.sessions, id)
	}
	r.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// handleLabToken trades the short lab code (easy to type on a car's screen) for a day-long token.
func (r *Relay) handleLabToken(w http.ResponseWriter, req *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	json.NewDecoder(http.MaxBytesReader(w, req.Body, 1024)).Decode(&body)
	if r.limited(req) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "Too many tries. Wait ten minutes."})
		return
	}
	if !r.codeMatches(body.Code) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "That code isn't right."})
		return
	}
	now := time.Now()
	writeJSON(w, 200, map[string]string{"token": signToken(r.cfg.Secret, "lab", now.Add(24*time.Hour))})
}

// MARK: Who may use the relay

func (r *Relay) ownersFile() string {
	if r.cfg.DataDir == "" {
		return ""
	}
	return filepath.Join(r.cfg.DataDir, "owners.json")
}

// person is someone allowed to use the relay. Whoever linked with the relay's code manages it (sees
// who else can use it, and removes them); people who joined by invitation just watch.
type person struct {
	Admin     bool   `json:"admin,omitempty"`
	InvitedBy string `json:"invitedBy,omitempty"`
	Since     int64  `json:"since,omitempty"`
}

type peopleFile struct {
	People map[string]person `json:"people"`
	Used   map[string]int64  `json:"usedInvites,omitempty"`
}

func (r *Relay) loadOwners() {
	path := r.ownersFile()
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	// The first version kept a plain list of the accounts linked with the code.
	var emails []string
	if json.Unmarshal(raw, &emails) == nil {
		for _, e := range emails {
			r.owners[strings.ToLower(e)] = person{Admin: true}
		}
		return
	}
	var f peopleFile
	if json.Unmarshal(raw, &f) == nil {
		for e, p := range f.People {
			r.owners[strings.ToLower(e)] = p
		}
		for id, exp := range f.Used {
			r.used[id] = exp
		}
	}
}

// saveOwners is called with the lock held.
func (r *Relay) saveOwners() {
	path := r.ownersFile()
	if path == "" {
		return
	}
	now := time.Now().Unix()
	for id, exp := range r.used {
		if exp < now {
			delete(r.used, id)
		}
	}
	raw, _ := json.MarshalIndent(peopleFile{People: r.owners, Used: r.used}, "", "  ")
	os.MkdirAll(r.cfg.DataDir, 0o700)
	os.WriteFile(path+".tmp", raw, 0o600)
	os.Rename(path+".tmp", path)
}

// limited counts a guess at the relay code from an address and says whether it has had too many.
func (r *Relay) limited(req *http.Request) bool {
	host, _, _ := net.SplitHostPort(req.RemoteAddr)
	if fwd := req.Header.Get("X-Forwarded-For"); fwd != "" {
		host = strings.TrimSpace(strings.Split(fwd, ",")[0])
	}
	now := time.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	recent := r.attempts[host][:0]
	for _, t := range r.attempts[host] {
		if now.Sub(t) < 10*time.Minute {
			recent = append(recent, t)
		}
	}
	if len(recent) >= 8 {
		r.attempts[host] = recent
		return true
	}
	r.attempts[host] = append(recent, now)
	return false
}

func (r *Relay) codeMatches(code string) bool {
	clean := func(s string) string {
		return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(s))
	}
	return len(r.cfg.LabCode) >= 8 && subtle.ConstantTimeCompare([]byte(clean(code)), []byte(clean(r.cfg.LabCode))) == 1
}

// handleAuth gives the web app a token. A Stremio account is linked to this relay once, by entering
// the relay's code on any device; after that, every device signed in to that account gets tokens by
// itself. The account is confirmed with Stremio each time.
func (r *Relay) handleAuth(w http.ResponseWriter, req *http.Request) {
	var body struct {
		AuthKey string `json:"authKey"`
		Code    string `json:"code"`
		Invite  string `json:"invite"`
	}
	json.NewDecoder(http.MaxBytesReader(w, req.Body, 4096)).Decode(&body)
	if body.AuthKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Sign in first."})
		return
	}
	email, err := r.stremioEmail(req.Context(), body.AuthKey)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Stremio didn't recognize this sign-in. Sign in again."})
		return
	}
	r.mu.Lock()
	_, known := r.owners[email]
	r.mu.Unlock()
	if !known && body.Invite != "" {
		if r.limited(req) {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "Too many tries. Wait ten minutes."})
			return
		}
		id, from, exp, ok := r.readInvite(body.Invite)
		r.mu.Lock()
		_, taken := r.used[id]
		if ok && !taken {
			r.used[id] = exp
			r.owners[email] = person{InvitedBy: from, Since: time.Now().Unix()}
			r.saveOwners()
			known = true
		}
		r.mu.Unlock()
		if !known {
			msg := "This invitation has expired. Ask for a new one."
			if taken {
				msg = "This invitation has already been used. Ask for a new one."
			}
			writeJSON(w, http.StatusForbidden, map[string]any{"error": msg, "needsCode": true})
			return
		}
	}
	if !known {
		if body.Code == "" {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "Enter this relay's code to link your account.", "needsCode": true})
			return
		}
		if r.limited(req) {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "Too many tries. Wait ten minutes."})
			return
		}
		if !r.codeMatches(body.Code) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "That code isn't right.", "needsCode": true})
			return
		}
		r.mu.Lock()
		r.owners[email] = person{Admin: true, Since: time.Now().Unix()}
		r.saveOwners()
		r.mu.Unlock()
	}
	expires := time.Now().Add(7 * 24 * time.Hour)
	r.mu.Lock()
	admin := r.owners[email].Admin
	r.mu.Unlock()
	writeJSON(w, 200, map[string]any{"token": signToken(r.cfg.Secret, email, expires), "expiresAt": expires.Unix(), "email": email, "admin": admin})
}

// Invitations are signed with their own key, so one can never be used as an access token.
func (r *Relay) inviteKey() string { return r.cfg.Secret + "|invite" }

// handleInvite makes a link that lets one more Stremio account use this relay, once, within 7 days.
func (r *Relay) handleInvite(w http.ResponseWriter, req *http.Request) {
	from := tokenSubject(strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer "))
	expires := time.Now().Add(7 * 24 * time.Hour)
	invite := signToken(r.inviteKey(), "invite:"+randomID()[:16]+":"+from, expires)
	writeJSON(w, 200, map[string]any{"invite": invite, "expiresAt": expires.Unix()})
}

func (r *Relay) readInvite(invite string) (id, from string, expires int64, ok bool) {
	if !verifyToken(r.inviteKey(), invite, time.Now()) {
		return "", "", 0, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.SplitN(invite, ".", 2)[0])
	if err != nil {
		return "", "", 0, false
	}
	parts := strings.SplitN(string(raw), ":", 4) // expiry:invite:id:from
	if len(parts) != 4 || parts[1] != "invite" {
		return "", "", 0, false
	}
	expires, _ = strconv.ParseInt(parts[0], 10, 64)
	return parts[2], parts[3], expires, true
}

// tokenSubject is who a (verified) token was made for.
func tokenSubject(token string) string {
	payload, _, _ := strings.Cut(token, ".")
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return ""
	}
	_, sub, _ := strings.Cut(string(raw), ":")
	return sub
}

// handlePeople lists who can use the relay, for the people who manage it.
func (r *Relay) handlePeople(w http.ResponseWriter, req *http.Request) {
	me := tokenSubject(strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer "))
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.owners[me].Admin {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "Only the people who manage this relay can see this."})
		return
	}
	type row struct {
		Email     string `json:"email"`
		Admin     bool   `json:"admin"`
		InvitedBy string `json:"invitedBy,omitempty"`
		Since     int64  `json:"since,omitempty"`
		You       bool   `json:"you,omitempty"`
	}
	list := []row{}
	for e, p := range r.owners {
		list = append(list, row{e, p.Admin, p.InvitedBy, p.Since, e == me})
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Admin != list[j].Admin {
			return list[i].Admin
		}
		return list[i].Email < list[j].Email
	})
	writeJSON(w, 200, map[string]any{"people": list})
}

// handleRemovePerson stops an account from using the relay, at once (its tokens stop working too).
func (r *Relay) handleRemovePerson(w http.ResponseWriter, req *http.Request) {
	me := tokenSubject(strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer "))
	who := strings.ToLower(req.PathValue("email"))
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.owners[me].Admin {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "Only the people who manage this relay can do this."})
		return
	}
	if who == me {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "You can't remove yourself."})
		return
	}
	delete(r.owners, who)
	r.saveOwners()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (r *Relay) stremioEmail(ctx context.Context, authKey string) (string, error) {
	base := r.cfg.StremioAPI
	if base == "" {
		base = "https://api.strem.io/api"
	}
	payload, _ := json.Marshal(map[string]string{"type": "GetUser", "authKey": authKey})
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/getUser", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(request)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Result *struct {
			Email string `json:"email"`
		} `json:"result"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil || out.Result == nil || out.Result.Email == "" {
		return "", errors.New("not signed in")
	}
	return strings.ToLower(out.Result.Email), nil
}

// MARK: The web app

// handleApp serves the built app: its files by name, and its page for every other address (the app
// routes by address itself).
func (r *Relay) handleApp(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/")
	if name == "" || strings.HasPrefix(name, "v1/") {
		name = "index.html"
	}
	raw, err := fs.ReadFile(webFiles, "web/"+name)
	if err != nil {
		if strings.HasPrefix(name, "assets/") || strings.Contains(filepath.Base(name), ".") {
			http.NotFound(w, req)
			return
		}
		name = "index.html"
		if raw, err = fs.ReadFile(webFiles, "web/index.html"); err != nil {
			http.Error(w, "The web app isn't part of this build. The lab page is at /lab.", http.StatusNotFound)
			return
		}
	}
	switch {
	case strings.HasPrefix(name, "assets/"):
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable") // named by content hash
	default:
		w.Header().Set("Cache-Control", "no-cache")
	}
	if name == "index.html" {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src * data: blob:; media-src * blob:; connect-src *; style-src 'self' 'unsafe-inline'; script-src 'self'; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'")
		w.Header().Set("Referrer-Policy", "no-referrer")
	}
	http.ServeContent(w, req, name, time.Time{}, bytes.NewReader(raw))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
