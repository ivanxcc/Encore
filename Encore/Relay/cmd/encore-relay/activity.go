package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// What was watched on the relay, and how well it played: for whoever manages it. Kept in the data
// folder only (RELAY_DATA/activity), one file of events a month. Plays older than 90 days are folded
// into monthly totals per person and their detail dropped.

const keepDays = 90

// Play is one film or episode, from its first frame to when it was left.
type Play struct {
	ID       string  `json:"id"`
	Who      string  `json:"who"`
	Profile  string  `json:"profile,omitempty"`
	Title    string  `json:"title"`
	Episode  string  `json:"episode,omitempty"` // "S1, E3 · Undertow"
	Type     string  `json:"type,omitempty"`
	MetaID   string  `json:"metaId,omitempty"`
	Quality  string  `json:"quality,omitempty"`
	Source   string  `json:"source,omitempty"`
	Mode     string  `json:"mode,omitempty"` // direct, remux, converted, proxied
	Device   string  `json:"device,omitempty"`
	Session  string  `json:"session,omitempty"`
	At       int64   `json:"at"`
	Updated  int64   `json:"updated"`
	Ended    int64   `json:"ended,omitempty"`
	StartMs  int     `json:"startMs,omitempty"`
	Watched  float64 `json:"watched"` // seconds of playing
	Stalls   int     `json:"stalls"`
	SeekMs   int     `json:"seekMs,omitempty"` // average
	Errors   int     `json:"errors"`
	Switches int     `json:"switches,omitempty"`
	Problem  string  `json:"problem,omitempty"`
}

// Total is a month of one person's watching.
type Total struct {
	Plays   int     `json:"plays"`
	Seconds float64 `json:"seconds"`
}

type activity struct {
	mu     sync.Mutex
	dir    string
	plays  []*Play
	byID   map[string]*Play
	totals map[string]map[string]Total // person -> "2026-08" -> total, for months whose detail was dropped
}

func openActivity(dataDir string) *activity {
	a := &activity{byID: map[string]*Play{}, totals: map[string]map[string]Total{}}
	if dataDir == "" {
		return a
	}
	a.dir = filepath.Join(dataDir, "activity")
	os.MkdirAll(a.dir, 0o700)
	if raw, err := os.ReadFile(filepath.Join(a.dir, "totals.json")); err == nil {
		json.Unmarshal(raw, &a.totals)
	}
	files, _ := filepath.Glob(filepath.Join(a.dir, "????-??.jsonl"))
	sort.Strings(files)
	for _, f := range files {
		a.load(f)
	}
	a.prune(time.Now())
	return a
}

type event struct {
	K string `json:"k"` // play, update
	Play
}

func (a *activity) load(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var e event
		if json.Unmarshal(sc.Bytes(), &e) != nil || e.ID == "" {
			continue
		}
		if e.K == "play" {
			p := e.Play
			if old := a.byID[p.ID]; old != nil {
				*old = p
				continue
			}
			a.plays = append(a.plays, &p)
			a.byID[p.ID] = &p
		} else if p := a.byID[e.ID]; p != nil {
			p.merge(e.Play)
		}
	}
}

// merge takes what a later report says about a play: it only grows.
func (p *Play) merge(u Play) {
	if u.Watched > p.Watched {
		p.Watched = u.Watched
	}
	if u.Stalls > p.Stalls {
		p.Stalls = u.Stalls
	}
	if u.Errors > p.Errors {
		p.Errors = u.Errors
	}
	if u.Switches > p.Switches {
		p.Switches = u.Switches
	}
	if u.SeekMs > 0 {
		p.SeekMs = u.SeekMs
	}
	if u.Session != "" {
		p.Session = u.Session
	}
	if u.Mode != "" {
		p.Mode = u.Mode
	}
	if u.Quality != "" {
		p.Quality, p.Source = u.Quality, u.Source
	}
	if u.Problem != "" {
		p.Problem = u.Problem
	}
	if u.Updated > p.Updated {
		p.Updated = u.Updated
	}
	if u.Ended > 0 {
		p.Ended = u.Ended
	}
}

func (a *activity) write(e event) {
	if a.dir == "" {
		return
	}
	raw, _ := json.Marshal(e)
	path := filepath.Join(a.dir, time.Unix(e.At, 0).UTC().Format("2006-01")+".jsonl")
	if e.K != "play" {
		path = filepath.Join(a.dir, time.Now().UTC().Format("2006-01")+".jsonl")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(raw, '\n'))
	f.Close()
}

// start records a play that has begun.
func (a *activity) start(p Play) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, ok := a.byID[p.ID]; ok {
		return
	}
	now := time.Now().Unix()
	p.At, p.Updated = now, now
	a.plays = append(a.plays, &p)
	a.byID[p.ID] = &p
	a.write(event{K: "play", Play: p})
}

// update records how a play is going (every half minute while playing, and when it's left). Only
// its owner can update it.
func (a *activity) update(who string, u Play) {
	a.mu.Lock()
	defer a.mu.Unlock()
	p := a.byID[u.ID]
	if p == nil || p.Who != who {
		return
	}
	u.Updated = time.Now().Unix()
	if u.Ended > 0 {
		u.Ended = u.Updated
	}
	p.merge(u)
	a.write(event{K: "update", Play: Play{ID: p.ID, At: p.At, Updated: p.Updated, Ended: p.Ended, Watched: p.Watched, Stalls: p.Stalls,
		Errors: p.Errors, Switches: p.Switches, SeekMs: p.SeekMs, Session: p.Session, Mode: p.Mode, Quality: p.Quality, Source: p.Source, Problem: p.Problem}})
}

// prune folds plays older than 90 days into monthly totals and deletes month files with nothing left.
func (a *activity) prune(now time.Time) {
	cutoff := now.Add(-keepDays * 24 * time.Hour).Unix()
	kept := a.plays[:0]
	changed := false
	for _, p := range a.plays {
		if p.At >= cutoff {
			kept = append(kept, p)
			continue
		}
		month := time.Unix(p.At, 0).UTC().Format("2006-01")
		if a.totals[p.Who] == nil {
			a.totals[p.Who] = map[string]Total{}
		}
		t := a.totals[p.Who][month]
		t.Plays++
		t.Seconds += p.Watched
		a.totals[p.Who][month] = t
		delete(a.byID, p.ID)
		changed = true
	}
	a.plays = kept
	if a.dir == "" || !changed {
		return
	}
	raw, _ := json.Marshal(a.totals)
	os.WriteFile(filepath.Join(a.dir, "totals.json.tmp"), raw, 0o600)
	os.Rename(filepath.Join(a.dir, "totals.json.tmp"), filepath.Join(a.dir, "totals.json"))
	// A month file goes once every play that started in it is older than the cut-off.
	oldest := time.Unix(cutoff, 0).UTC().Format("2006-01")
	files, _ := filepath.Glob(filepath.Join(a.dir, "????-??.jsonl"))
	for _, f := range files {
		if strings.TrimSuffix(filepath.Base(f), ".jsonl") < oldest {
			os.Remove(f)
		}
	}
}

// forget drops everything about a person (they were removed from the relay).
func (a *activity) forget(who string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	kept := a.plays[:0]
	for _, p := range a.plays {
		if p.Who == who {
			delete(a.byID, p.ID)
			continue
		}
		kept = append(kept, p)
	}
	a.plays = kept
	delete(a.totals, who)
	// The month files still hold the old lines; they are skipped on load once the person is gone.
}

// live is what's being watched now: plays reported in the last minute and a half, not left.
func (a *activity) live(now time.Time) []Play {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []Play{}
	for _, p := range a.plays {
		if p.Ended == 0 && now.Unix()-p.Updated < 90 {
			out = append(out, *p)
		}
	}
	return out
}

// of is a person's plays, newest first (at most n), and a summary.
func (a *activity) of(who string, n int) []Play {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := []Play{}
	for i := len(a.plays) - 1; i >= 0 && len(out) < n; i-- {
		if a.plays[i].Who == who {
			out = append(out, *a.plays[i])
		}
	}
	return out
}

type summary struct {
	Plays7    int     `json:"plays7"`
	Hours7    float64 `json:"hours7"`
	Plays30   int     `json:"plays30"`
	Hours30   float64 `json:"hours30"`
	StartMs   int     `json:"startMs"`       // median time to the first frame, last 30 days
	StallsPH  float64 `json:"stallsPerHour"` // last 30 days
	Errors30  int     `json:"errors30"`
	Converted int     `json:"converted30"`
}

func (a *activity) summarize(who string, now time.Time) summary {
	a.mu.Lock()
	defer a.mu.Unlock()
	var s summary
	var starts []int
	stalls, hours := 0, 0.0
	for _, p := range a.plays {
		if p.Who != who {
			continue
		}
		age := now.Unix() - p.At
		if age < 7*86400 {
			s.Plays7++
			s.Hours7 += p.Watched / 3600
		}
		if age < 30*86400 {
			s.Plays30++
			s.Hours30 += p.Watched / 3600
			s.Errors30 += p.Errors
			stalls += p.Stalls
			hours += p.Watched / 3600
			if p.StartMs > 0 {
				starts = append(starts, p.StartMs)
			}
			if p.Mode == "converted" {
				s.Converted++
			}
		}
	}
	if len(starts) > 0 {
		sort.Ints(starts)
		s.StartMs = starts[len(starts)/2]
	}
	if hours > 0.05 {
		s.StallsPH = float64(stalls) / hours
	}
	return s
}

// months is a person's watching by month: the detail kept, and the totals of older months.
func (a *activity) months(who string) map[string]Total {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := map[string]Total{}
	for m, t := range a.totals[who] {
		out[m] = t
	}
	for _, p := range a.plays {
		if p.Who != who {
			continue
		}
		m := time.Unix(p.At, 0).UTC().Format("2006-01")
		t := out[m]
		t.Plays++
		t.Seconds += p.Watched
		out[m] = t
	}
	return out
}
