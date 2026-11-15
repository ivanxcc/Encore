package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"encore/relay/internal/hls"
	"encore/relay/internal/source"
)

// handleSubtitle fetches a subtitle file an add-on offered (SRT or WebVTT, possibly gzipped, in
// whatever text encoding) and returns its cues. Subtitle hosts rarely let a web page read their files
// directly, and their encodings vary; the relay settles both.
func (r *Relay) handleSubtitle(w http.ResponseWriter, req *http.Request) {
	address := req.URL.Query().Get("url")
	if !strings.HasPrefix(address, "http://") && !strings.HasPrefix(address, "https://") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Expected a subtitle address."})
		return
	}
	resp, err := source.Client(r.cfg.AllowPrivate).Get(address)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "The subtitles couldn't be fetched."})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "The subtitle host refused (HTTP " + strconv.Itoa(resp.StatusCode) + ")."})
		return
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "The subtitles couldn't be read."})
		return
	}
	cues := parseSubtitles(decodeText(raw))
	if len(cues) == 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "These subtitles are in a format Encore doesn't read."})
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=3600")
	writeJSON(w, 200, map[string]any{"cues": cues})
}

// decodeText turns a subtitle file into UTF-8: gzip is opened; UTF-16 and old single-byte encodings
// (Windows-1252, the usual one for older SRT files) are converted.
func decodeText(raw []byte) string {
	if len(raw) > 2 && raw[0] == 0x1f && raw[1] == 0x8b {
		if z, err := gzip.NewReader(bytes.NewReader(raw)); err == nil {
			if opened, err := io.ReadAll(io.LimitReader(z, 8<<20)); err == nil {
				raw = opened
			}
		}
	}
	switch {
	case bytes.HasPrefix(raw, []byte{0xEF, 0xBB, 0xBF}):
		return string(raw[3:])
	case bytes.HasPrefix(raw, []byte{0xFF, 0xFE}), bytes.HasPrefix(raw, []byte{0xFE, 0xFF}):
		little := raw[0] == 0xFF
		units := make([]uint16, 0, len(raw)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			if little {
				units = append(units, uint16(raw[i])|uint16(raw[i+1])<<8)
			} else {
				units = append(units, uint16(raw[i])<<8|uint16(raw[i+1]))
			}
		}
		return string(utf16.Decode(units))
	case utf8.Valid(raw):
		return string(raw)
	}
	var b strings.Builder
	for _, c := range raw {
		if r, ok := cp1252[c]; ok {
			b.WriteRune(r)
		} else {
			b.WriteRune(rune(c))
		}
	}
	return b.String()
}

// The Windows-1252 characters that differ from Latin-1.
var cp1252 = map[byte]rune{0x80: '€', 0x82: '‚', 0x83: 'ƒ', 0x84: '„', 0x85: '…', 0x86: '†', 0x87: '‡', 0x88: 'ˆ', 0x89: '‰',
	0x8A: 'Š', 0x8B: '‹', 0x8C: 'Œ', 0x8E: 'Ž', 0x91: '‘', 0x92: '’', 0x93: '“', 0x94: '”', 0x95: '•', 0x96: '–', 0x97: '—',
	0x98: '˜', 0x99: '™', 0x9A: 'š', 0x9B: '›', 0x9C: 'œ', 0x9E: 'ž', 0x9F: 'Ÿ'}

var (
	timing   = regexp.MustCompile(`(\d{1,2}:)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d{1,2}:)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})`)
	assTags  = regexp.MustCompile(`\{\\[^}]*\}`)
	htmlTags = regexp.MustCompile(`</?([a-zA-Z]+)[^>]*>`)
)

// parseSubtitles reads SRT and WebVTT alike: every block with a timing line is a cue. Only <i>, <b>,
// and <u> are kept of the markup.
func parseSubtitles(text string) []hls.Cue {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	var cues []hls.Cue
	for _, block := range strings.Split(text, "\n\n") {
		lines := strings.Split(strings.Trim(block, "\n"), "\n")
		for i, line := range lines {
			m := timing.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			body := strings.TrimSpace(strings.Join(lines[i+1:], "\n"))
			body = assTags.ReplaceAllString(body, "")
			body = htmlTags.ReplaceAllStringFunc(body, func(tag string) string {
				name := strings.ToLower(htmlTags.FindStringSubmatch(tag)[1])
				if name == "i" || name == "b" || name == "u" {
					return strings.ToLower(tag[:strings.Index(tag, name)+1]) + ">"
				}
				return ""
			})
			if body != "" {
				cues = append(cues, hls.Cue{Start: clockTime(m[1:5]), End: clockTime(m[5:9]), Text: body})
			}
			break
		}
	}
	return cues
}

func clockTime(p []string) float64 {
	h, _ := strconv.Atoi(strings.TrimSuffix(p[0], ":"))
	m, _ := strconv.Atoi(p[1])
	s, _ := strconv.Atoi(p[2])
	ms, _ := strconv.Atoi((p[3] + "00")[:3])
	return float64(h*3600+m*60+s) + float64(ms)/1000
}
