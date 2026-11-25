package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"encore/relay/internal/source"
)

// The owner's view of the relay: what's playing, how the server is doing, who uses it and how well
// it plays for them, invitations, and the add-ons offered to new people. Everything here is for the
// people who manage the relay (adminOnly), except the reports players send about their own plays.

// MARK: Traffic and problems, in memory (since the relay started)

type meter struct {
	mu       sync.Mutex
	hours    [48]struct{ hour, bytes int64 }
	problems []problem
}

type problem struct {
	At   int64  `json:"at"`
	Who  string `json:"who,omitempty"`
	What string `json:"what"`
}

func (m *meter) add(n int64) {
	hour := time.Now().Unix() / 3600
	m.mu.Lock()
	b := &m.hours[hour%48]
	if b.hour != hour {
		b.hour, b.bytes = hour, 0
	}
	b.bytes += n
	m.mu.Unlock()
}

func (m *meter) problem(who, what string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.problems = append(m.problems, problem{time.Now().Unix(), who, what})
	if len(m.problems) > 40 {
		m.problems = m.problems[len(m.problems)-40:]
	}
}

// counting counts what's written to a viewer.
type counting struct {
	http.ResponseWriter
	m *meter
}

func (c counting) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	c.m.add(int64(n))
	return n, err
}

func (c counting) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// MARK: Playing straight from the source, through the relay

// passthrough is a file a browser plays as it is, fetched through the relay rather than from the
// source: the source sees one address (the server's), and the owner sees the traffic.
type passthrough struct {
	url      string
	headers  map[string]string
	owner    string
	lastUsed time.Time
}

func (r *Relay) addPassthrough(url string, headers map[string]string, owner string) string {
	id := randomID()
	r.mu.Lock()
	defer r.mu.Unlock()
	for k, p := range r.through {
		if time.Since(p.lastUsed) > idleLimit {
			delete(r.through, k)
		}
	}
	r.through[id] = &passthrough{url: url, headers: headers, owner: owner, lastUsed: time.Now()}
	return id
}

func (r *Relay) handlePassthrough(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	p := r.through[req.PathValue("id")]
	if p != nil {
		p.lastUsed = time.Now()
	}
	r.mu.Unlock()
	if p == nil || r.paused(p.owner) || r.removed(p.owner) {
		http.NotFound(w, req)
		return
	}
	out, err := http.NewRequestWithContext(req.Context(), http.MethodGet, p.url, nil)
	if err != nil {
		http.Error(w, "bad source", http.StatusBadGateway)
		return
	}
	for k, v := range p.headers {
		out.Header.Set(k, v)
	}
	if rg := req.Header.Get("Range"); rg != "" {
		out.Header.Set("Range", rg)
	}
	resp, err := source.StreamClient(r.cfg.AllowPrivate).Do(out)
	if err != nil {
		http.Error(w, "The source didn't answer.", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.Header().Set("Cache-Control", "private, no-transform")
	w.WriteHeader(resp.StatusCode)
	io.Copy(counting{w, &r.meter}, resp.Body)
}

// MARK: Reports from players

// handleReport takes a player's report about its own play: started, how it's going, left. A report
// sent as the page closes can't carry a header, so the token may come in the body.
func (r *Relay) handleReport(w http.ResponseWriter, req *http.Request) {
	var body struct {
		Token    string `json:"token"`
		Kind     string `json:"kind"` // play, update, end, profiles, problem
		Play     Play   `json:"play"`
		Profiles []struct {
			Name   string `json:"name"`
			Avatar string `json:"avatar,omitempty"`
			Kids   bool   `json:"kids,omitempty"`
			Pin    bool   `json:"pin,omitempty"`
		} `json:"profiles"`
		Device string `json:"device"`
		What   string `json:"what"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 16<<10)).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected JSON."})
		return
	}
	token := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
	if token == "" {
		token = body.Token
	}
	who := tokenSubject(token)
	if !verifyToken(r.cfg.Secret, token, time.Now()) || !strings.Contains(who, "@") || r.removed(who) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "A valid token is required."})
		return
	}
	clip := func(s string, n int) string {
		if len(s) > n {
			return s[:n]
		}
		return s
	}
	switch body.Kind {
	case "play":
		p := body.Play
		if p.ID == "" || len(p.ID) > 40 {
			break
		}
		p.Who = who
		p.Title, p.Episode, p.Profile = clip(p.Title, 200), clip(p.Episode, 200), clip(p.Profile, 60)
		p.Source, p.Device = clip(p.Source, 200), clip(p.Device, 60)
		p.Watched, p.Ended, p.Stalls, p.Errors = 0, 0, 0, 0
		r.activity.start(p)
		r.noteDevice(who, p.Device)
	case "update", "end":
		u := body.Play
		u.Problem = clip(u.Problem, 200)
		u.Source = clip(u.Source, 200)
		if body.Kind == "end" {
			u.Ended = 1
		}
		r.activity.update(who, u)
		if u.Problem != "" {
			r.meter.problem(who, u.Problem)
		}
	case "problem":
		r.meter.problem(who, clip(body.What, 200))
	case "profiles":
		var list []profileInfo
		for _, p := range body.Profiles {
			if len(list) < 12 {
				list = append(list, profileInfo{Name: clip(p.Name, 60), Avatar: clip(p.Avatar, 40), Kids: p.Kids, Pin: p.Pin})
			}
		}
		r.mu.Lock()
		if p, ok := r.owners[who]; ok {
			p.Profiles = list
			r.owners[who] = p
			r.saveOwners()
		}
		r.mu.Unlock()
		r.noteDevice(who, clip(body.Device, 60))
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

type profileInfo struct {
	Name   string `json:"name"`
	Avatar string `json:"avatar,omitempty"`
	Kids   bool   `json:"kids,omitempty"`
	Pin    bool   `json:"pin,omitempty"`
}

// noteDevice remembers the devices someone uses ("iPad · Safari"), with when each was last used.
func (r *Relay) noteDevice(who, device string) {
	if device == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.owners[who]
	if !ok {
		return
	}
	if p.Devices == nil {
		p.Devices = map[string]int64{}
	}
	now := time.Now().Unix()
	if now-p.Devices[device] < 600 {
		return
	}
	p.Devices[device] = now
	if len(p.Devices) > 12 { // the least recent goes
		oldest, at := "", now
		for d, t := range p.Devices {
			if t < at {
				oldest, at = d, t
			}
		}
		delete(p.Devices, oldest)
	}
	r.owners[who] = p
	r.saveOwners()
}

// MARK: The owner's views

func (r *Relay) handleOverview(w http.ResponseWriter, req *http.Request) {
	now := time.Now()
	type liveRow struct {
		Play
		Name string `json:"name,omitempty"`
	}
	live := []liveRow{}
	r.mu.Lock()
	names := map[string]string{}
	for e, p := range r.owners {
		names[e] = p.Name
	}
	converting := 0
	sessions := len(r.sessions)
	for _, s := range r.sessions {
		if s.Converting() && s.Idle() < 2*time.Minute {
			converting++
		}
	}
	r.mu.Unlock()
	for _, p := range r.activity.live(now) {
		live = append(live, liveRow{p, names[p.Who]})
	}
	type hourRow struct {
		Hour  int64 `json:"hour"`
		Bytes int64 `json:"bytes"`
	}
	traffic := []hourRow{}
	this := now.Unix() / 3600
	r.meter.mu.Lock()
	for h := this - 47; h <= this; h++ {
		b := r.meter.hours[h%48]
		row := hourRow{Hour: h * 3600}
		if b.hour == h {
			row.Bytes = b.bytes
		}
		traffic = append(traffic, row)
	}
	problems := append([]problem{}, r.meter.problems...)
	r.meter.mu.Unlock()
	sort.Slice(problems, func(i, j int) bool { return problems[i].At > problems[j].At })

	server := map[string]any{
		"version": buildVersion(), "uptime": int64(now.Sub(r.started).Seconds()), "cpus": runtime.NumCPU(),
		"load": loadAverage(), "memory": memoryUse(), "dataBytes": dirSize(r.cfg.DataDir),
		"converting": converting, "streams": sessions, "convertMode": r.conversionLabel(),
	}
	writeJSON(w, 200, map[string]any{"server": server, "live": live, "traffic": traffic, "problems": problems})
}

// handlePerson is everything about one person: their settings, profiles, devices, history, and how
// well things played for them.
func (r *Relay) handlePerson(w http.ResponseWriter, req *http.Request) {
	who := strings.ToLower(req.PathValue("email"))
	r.mu.Lock()
	p, ok := r.owners[who]
	watching := r.watchingLocked(who)
	r.mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No one by that address uses this server."})
		return
	}
	limit := p.Streams
	if limit == 0 && !p.Admin {
		limit = defaultStreams
	}
	writeJSON(w, 200, map[string]any{
		"email": who, "name": p.Name, "admin": p.Admin, "invitedBy": p.InvitedBy, "since": p.Since, "lastSeen": p.LastSeen,
		"paused": p.Paused, "streams": limit, "convert": p.Admin || p.Convert, "direct": r.mayDirect(who), "watching": watching,
		"profiles": p.Profiles, "devices": p.Devices,
		"plays": r.activity.of(who, 300), "summary": r.activity.summarize(who, time.Now()), "months": r.activity.months(who),
	})
}

// handleEndPlay stops a stream someone is watching (from the owner's Watching Now).
func (r *Relay) handleEndPlay(w http.ResponseWriter, req *http.Request) {
	id := req.PathValue("id")
	r.activity.mu.Lock()
	p := r.activity.byID[id]
	session := ""
	if p != nil {
		session = p.Session
		p.Ended = time.Now().Unix()
	}
	r.activity.mu.Unlock()
	if p == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "Not playing."})
		return
	}
	r.mu.Lock()
	if s := r.sessions[session]; s != nil {
		s.Close()
		delete(r.sessions, session)
	}
	delete(r.through, session)
	r.mu.Unlock()
	writeJSON(w, 200, map[string]any{"ok": true})
}

// MARK: Invitations

type inviteRecord struct {
	ID      string `json:"id"`
	Label   string `json:"label,omitempty"`
	By      string `json:"by"`
	Link    string `json:"invite,omitempty"` // the invitation itself, to share again while it's open
	Created int64  `json:"created"`
	Expires int64  `json:"expires"`
	UsedBy  string `json:"usedBy,omitempty"`
	UsedAt  int64  `json:"usedAt,omitempty"`
	Revoked bool   `json:"revoked,omitempty"`
}

func (r *Relay) handleInvites(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	list := []inviteRecord{}
	for _, inv := range r.invites {
		row := *inv
		if row.UsedBy != "" || row.Revoked || row.Expires < time.Now().Unix() {
			row.Link = ""
		}
		list = append(list, row)
	}
	r.mu.Unlock()
	sort.Slice(list, func(i, j int) bool { return list[i].Created > list[j].Created })
	writeJSON(w, 200, map[string]any{"invites": list})
}

func (r *Relay) handleRevokeInvite(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	inv := r.invites[req.PathValue("id")]
	if inv == nil || inv.UsedBy != "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No open invitation by that id."})
		return
	}
	inv.Revoked = true
	r.saveOwners()
	writeJSON(w, 200, map[string]any{"ok": true})
}

// MARK: Add-ons offered to new people

func (r *Relay) handleGetStarter(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	list := r.starter
	from := ""
	for _, p := range r.owners {
		if p.Admin && from == "" {
			from = p.Name
		}
	}
	r.mu.Unlock()
	if list == nil {
		list = []json.RawMessage{}
	}
	writeJSON(w, 200, map[string]any{"addons": list, "from": from})
}

func (r *Relay) handlePutStarter(w http.ResponseWriter, req *http.Request) {
	var body struct {
		Addons []json.RawMessage `json:"addons"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 1<<20)).Decode(&body); err != nil || len(body.Addons) > 60 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected a list of add-ons."})
		return
	}
	r.mu.Lock()
	r.starter = body.Addons
	r.saveOwners()
	r.mu.Unlock()
	writeJSON(w, 200, map[string]any{"ok": true})
}

// MARK: The machine

func buildVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	rev, when := "", ""
	for _, s := range info.Settings {
		switch s.Key {
		case "vcs.revision":
			if len(s.Value) >= 7 {
				rev = s.Value[:7]
			}
		case "vcs.time":
			when = s.Value
		}
	}
	if rev == "" {
		return "development build"
	}
	if t, err := time.Parse(time.RFC3339, when); err == nil {
		return rev + " · " + t.Format("Jan 2, 2006")
	}
	return rev
}

// loadAverage is the last minute's load as a share of the processors (1 = all busy).
func loadAverage() float64 {
	raw, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return -1
	}
	v, _ := strconv.ParseFloat(strings.Fields(string(raw))[0], 64)
	return v / float64(runtime.NumCPU())
}

// memoryUse is the share of the machine's memory in use (-1 if unknown).
func memoryUse() float64 {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return -1
	}
	var total, avail float64
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		v, _ := strconv.ParseFloat(f[1], 64)
		switch f[0] {
		case "MemTotal:":
			total = v
		case "MemAvailable:":
			avail = v
		}
	}
	if total == 0 {
		return -1
	}
	return 1 - avail/total
}

func dirSize(dir string) int64 {
	if dir == "" {
		return 0
	}
	var n int64
	filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			n += info.Size()
		}
		return nil
	})
	return n
}

func (r *Relay) conversionLabel() string {
	c := r.conversion(false)
	if c == nil {
		return "off"
	}
	return strconv.Itoa(c.Height) + "p"
}
