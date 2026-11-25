package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// Who may do what. Whoever linked with the relay code manages the relay: they invite people, see who
// uses it and how, pause or remove them, and set their limits. People who joined by invitation watch.
// Tokens for the lab and the command line (not an account) are the owner's own tools.

const (
	defaultStreams = 2
	pausedMessage  = "Your access to this server is paused. Ask its owner if you think that's a mistake."
)

func (r *Relay) isAdmin(sub string) bool {
	if sub == "" {
		return false
	}
	if !strings.Contains(sub, "@") {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.owners[sub].Admin
}

// adminOnly is authed, for the people who manage the relay.
func (r *Relay) adminOnly(next http.HandlerFunc) http.HandlerFunc {
	return r.authed(func(w http.ResponseWriter, req *http.Request) {
		if !r.isAdmin(tokenSubject(strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer "))) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "Only the people who manage this server can do this."})
			return
		}
		next(w, req)
	})
}

func (r *Relay) paused(sub string) bool {
	if !strings.Contains(sub, "@") {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.owners[sub].Paused
}

// codeSignupOpen: the relay code links new accounts only until someone manages the relay (unless
// RELAY_CODE_SIGNUP=on).
func (r *Relay) codeSignupOpen() bool {
	if r.cfg.CodeSignup {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, p := range r.owners {
		if p.Admin {
			return false
		}
	}
	return true
}

func (r *Relay) mayConvert(sub string) bool {
	if !strings.Contains(sub, "@") {
		return true
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.owners[sub]
	return p.Admin || p.Convert
}

// streamLimit is how many streams an account may watch at once (0: no limit) and how many it is
// watching: streams a player has asked for, used in the last minute and a half.
func (r *Relay) streamLimit(sub string) (int, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !strings.Contains(sub, "@") {
		return 0, 0
	}
	p := r.owners[sub]
	limit := p.Streams
	if limit == 0 {
		if p.Admin {
			return 0, 0
		}
		limit = defaultStreams
	}
	return limit, r.watchingLocked(sub)
}

func (r *Relay) watchingLocked(sub string) int {
	n := 0
	for _, s := range r.sessions {
		if s.Owner == sub && s.Claimed() && s.Idle() < 90*time.Second {
			n++
		}
	}
	return n
}

// endStreamsLocked closes an account's streams (paused or removed). Called with the lock held.
func (r *Relay) endStreamsLocked(sub string) {
	for id, s := range r.sessions {
		if s.Owner == sub {
			s.Close()
			delete(r.sessions, id)
		}
	}
}

// seen notes when an account last signed in or started something (saved at most every few minutes).
func (r *Relay) seen(sub string) {
	if !strings.Contains(sub, "@") {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.owners[sub]
	now := time.Now().Unix()
	if !ok || now-p.LastSeen < 300 {
		return
	}
	p.LastSeen = now
	r.owners[sub] = p
	r.saveOwners()
}

// handleChangePerson pauses or resumes someone, or changes their limits: {paused?, streams?, convert?}.
func (r *Relay) handleChangePerson(w http.ResponseWriter, req *http.Request) {
	me := tokenSubject(strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer "))
	who := strings.ToLower(req.PathValue("email"))
	var body struct {
		Paused  *bool `json:"paused"`
		Streams *int  `json:"streams"`
		Convert *bool `json:"convert"`
	}
	if err := readJSON(w, req, &body); err != nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.owners[who]
	switch {
	case !ok:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "No one by that address uses this server."})
		return
	case who == me && body.Paused != nil && *body.Paused:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "You can't pause yourself."})
		return
	}
	if body.Paused != nil {
		p.Paused = *body.Paused
	}
	if body.Streams != nil && *body.Streams >= 0 && *body.Streams <= 10 {
		p.Streams = *body.Streams
	}
	if body.Convert != nil {
		p.Convert = *body.Convert
	}
	r.owners[who] = p
	r.saveOwners()
	if p.Paused {
		r.endStreamsLocked(who)
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func readJSON(w http.ResponseWriter, req *http.Request, v any) error {
	if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 4096)).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected JSON."})
		return err
	}
	return nil
}
