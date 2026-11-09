// Package mkv reads what the relay needs from a Matroska file over ranged reads: its tracks, its
// keyframe index (Cues), and a minimal stream header. Nothing here reads the media itself, so a
// multi-gigabyte file is understood from a few hundred kilobytes.
package mkv

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"sort"
)

// Reader fetches a byte range of the file. A short read at the end of the file is not an error.
type Reader interface {
	ReadAt(ctx context.Context, off int64, n int) ([]byte, error)
}

const (
	idEBML           = 0x1A45DFA3
	idSegment        = 0x18538067
	idSeekHead       = 0x114D9B74
	idSeek           = 0x4DBB
	idSeekID         = 0x53AB
	idSeekPosition   = 0x53AC
	idInfo           = 0x1549A966
	idTimestampScale = 0x2AD7B1
	idDuration       = 0x4489
	idTracks         = 0x1654AE6B
	idTrackEntry     = 0xAE
	idTrackNumber    = 0xD7
	idTrackType      = 0x83
	idCodecID        = 0x86
	idCodecPrivate   = 0x63A2
	idLanguage       = 0x22B59C
	idLanguageBCP47  = 0x22B59D
	idName           = 0x536E
	idFlagDefault    = 0x88
	idFlagForced     = 0x55AA
	idVideo          = 0xE0
	idPixelWidth     = 0xB0
	idPixelHeight    = 0xBA
	idColour         = 0x55B0
	idTransfer       = 0x55BA
	idAudio          = 0xE1
	idChannels       = 0x9F
	idSamplingFreq   = 0xB5
	idCues           = 0x1C53BB6B
	idCuePoint       = 0xBB
	idCueTime        = 0xB3
	idCueTrackPos    = 0xB7
	idCueTrack       = 0xF7
	idCueClusterPos  = 0xF1
	idCluster        = 0x1F43B675
)

const (
	TrackVideo    = 1
	TrackAudio    = 2
	TrackSubtitle = 17
)

type Track struct {
	Number       uint64
	Type         int
	CodecID      string
	Language     string
	Name         string
	Default      bool
	Forced       bool
	Width        int
	Height       int
	Channels     int
	SampleRate   float64
	Transfer     int    // video transfer characteristics: 16 = PQ (HDR10), 18 = HLG
	CodecPrivate []byte // video only (avcC / hvcC)
}

// Cue is a keyframe of the video track: when it is shown, and the file offset of its cluster.
type Cue struct {
	Time   float64
	Offset int64
}

type File struct {
	// Header is a self-contained stream header (EBML header, an unknown-size Segment, Info, Tracks).
	// Header followed by the file's bytes from any Cue.Offset is a valid Matroska stream.
	Header   []byte
	Duration float64
	Tracks   []Track
	Cues     []Cue
}

var (
	ErrNotMatroska = errors.New("not a Matroska file")
	ErrNoIndex     = errors.New("the file has no keyframe index")
	ErrMalformed   = errors.New("malformed Matroska file")
)

// Video returns the first video track.
func (f *File) Video() *Track {
	for i := range f.Tracks {
		if f.Tracks[i].Type == TrackVideo {
			return &f.Tracks[i]
		}
	}
	return nil
}

// Of returns the tracks of one type, in file order.
func (f *File) Of(kind int) []Track {
	var out []Track
	for _, t := range f.Tracks {
		if t.Type == kind {
			out = append(out, t)
		}
	}
	return out
}

// Parse reads the header and the index. With ErrNoIndex the returned File still describes the tracks.
func Parse(ctx context.Context, r Reader) (*File, error) {
	w := &window{r: r, ctx: ctx}
	head, err := w.bytes(0, 64)
	if err != nil {
		return nil, err
	}
	id, n, ok := readID(head)
	if !ok || id != idEBML {
		return nil, ErrNotMatroska
	}
	size, sn, ok := readSize(head[n:])
	if !ok || size < 0 || size > 1<<16 {
		return nil, ErrMalformed
	}
	ebmlEnd := int64(n+sn) + size
	ebmlHeader, err := w.bytes(0, int(ebmlEnd))
	if err != nil || int64(len(ebmlHeader)) < ebmlEnd {
		return nil, ErrMalformed
	}
	ebmlHeader = append([]byte(nil), ebmlHeader...)

	seg, err := w.bytes(ebmlEnd, 16)
	if err != nil {
		return nil, err
	}
	id, n, ok = readID(seg)
	if !ok || id != idSegment {
		return nil, ErrMalformed
	}
	_, sn, ok = readSize(seg[n:])
	if !ok {
		return nil, ErrMalformed
	}
	data := ebmlEnd + int64(n+sn) // positions in SeekHead and Cues are relative to here

	var info, tracks []byte
	var infoAt, tracksAt, cuesAt int64 = -1, -1, -1
	pos := data
	for i := 0; i < 256; i++ {
		hdr, err := w.bytes(pos, 12)
		if err != nil || len(hdr) < 2 {
			break
		}
		id, n, ok := readID(hdr)
		if !ok {
			break
		}
		size, sn, ok := readSize(hdr[n:])
		if !ok {
			break
		}
		body := pos + int64(n+sn)
		if id == idCluster {
			break
		}
		if size < 0 {
			break
		}
		switch id {
		case idSeekHead:
			if size <= 1<<20 {
				b, err := w.bytes(body, int(size))
				if err == nil {
					each(b, func(id uint32, e []byte) {
						if id != idSeek {
							return
						}
						var target uint32
						var at int64 = -1
						each(e, func(id uint32, v []byte) {
							switch id {
							case idSeekID:
								target = uint32(readUint(v))
							case idSeekPosition:
								at = int64(readUint(v))
							}
						})
						if at < 0 {
							return
						}
						switch target {
						case idInfo:
							infoAt = data + at
						case idTracks:
							tracksAt = data + at
						case idCues:
							cuesAt = data + at
						}
					})
				}
			}
		case idInfo:
			infoAt = pos
		case idTracks:
			tracksAt = pos
		case idCues:
			cuesAt = pos
		}
		if infoAt >= 0 && tracksAt >= 0 && cuesAt >= 0 {
			break
		}
		pos = body + size
	}

	if infoAt < 0 || tracksAt < 0 {
		return nil, ErrMalformed
	}
	if info, err = w.element(infoAt, idInfo, 1<<20); err != nil {
		return nil, err
	}
	if tracks, err = w.element(tracksAt, idTracks, 8<<20); err != nil {
		return nil, err
	}

	f := &File{}
	scale := uint64(1_000_000)
	var rawDuration float64
	each(elementBody(info), func(id uint32, v []byte) {
		switch id {
		case idTimestampScale:
			scale = readUint(v)
		case idDuration:
			rawDuration = readFloat(v)
		}
	})
	if scale == 0 {
		scale = 1_000_000
	}
	f.Duration = rawDuration * float64(scale) / 1e9
	each(elementBody(tracks), func(id uint32, e []byte) {
		if id != idTrackEntry {
			return
		}
		t := Track{Default: true, Language: "eng"}
		each(e, func(id uint32, v []byte) {
			switch id {
			case idTrackNumber:
				t.Number = readUint(v)
			case idTrackType:
				t.Type = int(readUint(v))
			case idCodecID:
				t.CodecID = string(v)
			case idLanguage:
				t.Language = string(v)
			case idLanguageBCP47:
				t.Language = string(v)
			case idName:
				t.Name = string(v)
			case idFlagDefault:
				t.Default = readUint(v) != 0
			case idFlagForced:
				t.Forced = readUint(v) != 0
			case idCodecPrivate:
				if len(v) <= 4096 {
					t.CodecPrivate = append([]byte(nil), v...)
				}
			case idVideo:
				each(v, func(id uint32, x []byte) {
					switch id {
					case idPixelWidth:
						t.Width = int(readUint(x))
					case idPixelHeight:
						t.Height = int(readUint(x))
					case idColour:
						each(x, func(id uint32, c []byte) {
							if id == idTransfer {
								t.Transfer = int(readUint(c))
							}
						})
					}
				})
			case idAudio:
				each(v, func(id uint32, x []byte) {
					switch id {
					case idChannels:
						t.Channels = int(readUint(x))
					case idSamplingFreq:
						t.SampleRate = readFloat(x)
					}
				})
			}
		})
		if t.Type != TrackVideo {
			t.CodecPrivate = nil
		}
		f.Tracks = append(f.Tracks, t)
	})

	f.Header = append(f.Header, ebmlHeader...)
	f.Header = append(f.Header, 0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
	f.Header = append(f.Header, info...)
	f.Header = append(f.Header, tracks...)

	video := f.Video()
	if video == nil {
		return f, ErrMalformed
	}
	if cuesAt < 0 {
		return f, ErrNoIndex
	}
	cues, err := w.element(cuesAt, idCues, 64<<20)
	if err != nil {
		return f, ErrNoIndex
	}
	each(elementBody(cues), func(id uint32, e []byte) {
		if id != idCuePoint {
			return
		}
		var time uint64
		var offset int64 = -1
		each(e, func(id uint32, v []byte) {
			switch id {
			case idCueTime:
				time = readUint(v)
			case idCueTrackPos:
				var track uint64
				var at int64 = -1
				each(v, func(id uint32, x []byte) {
					switch id {
					case idCueTrack:
						track = readUint(x)
					case idCueClusterPos:
						at = int64(readUint(x))
					}
				})
				if track == video.Number && at >= 0 {
					offset = data + at
				}
			}
		})
		if offset >= 0 {
			f.Cues = append(f.Cues, Cue{Time: float64(time) * float64(scale) / 1e9, Offset: offset})
		}
	})
	sort.SliceStable(f.Cues, func(i, j int) bool { return f.Cues[i].Time < f.Cues[j].Time })
	out := f.Cues[:0]
	for _, c := range f.Cues {
		if len(out) == 0 || c.Time > out[len(out)-1].Time {
			out = append(out, c)
		}
	}
	f.Cues = out
	if len(f.Cues) < 2 {
		return f, ErrNoIndex
	}
	if f.Duration <= f.Cues[len(f.Cues)-1].Time {
		f.Duration = f.Cues[len(f.Cues)-1].Time + 1
	}
	return f, nil
}

// window keeps the last fetched range, so walking small neighbouring elements costs one request.
type window struct {
	r   Reader
	ctx context.Context
	off int64
	buf []byte
}

func (w *window) bytes(off int64, n int) ([]byte, error) {
	if off >= w.off && off+int64(n) <= w.off+int64(len(w.buf)) {
		s := off - w.off
		return w.buf[s : s+int64(n)], nil
	}
	want := n
	if want < 256<<10 {
		want = 256 << 10
	}
	b, err := w.r.ReadAt(w.ctx, off, want)
	if err != nil {
		return nil, err
	}
	w.off, w.buf = off, b
	if len(b) < n {
		return b, nil
	}
	return b[:n], nil
}

// element returns a whole element (header and body) that must have the given id.
func (w *window) element(at int64, want uint32, limit int64) ([]byte, error) {
	hdr, err := w.bytes(at, 12)
	if err != nil {
		return nil, err
	}
	id, n, ok := readID(hdr)
	if !ok || id != want {
		return nil, ErrMalformed
	}
	size, sn, ok := readSize(hdr[n:])
	if !ok || size < 0 || size > limit {
		return nil, ErrMalformed
	}
	total := n + sn + int(size)
	b, err := w.bytes(at, total)
	if err != nil {
		return nil, err
	}
	if len(b) < total {
		return nil, ErrMalformed
	}
	return append([]byte(nil), b...), nil
}

func elementBody(e []byte) []byte {
	_, n, ok := readID(e)
	if !ok {
		return nil
	}
	_, sn, ok := readSize(e[n:])
	if !ok {
		return nil
	}
	return e[n+sn:]
}

// each calls fn for every child element of a master element's body.
func each(b []byte, fn func(id uint32, body []byte)) {
	for len(b) > 0 {
		id, n, ok := readID(b)
		if !ok {
			return
		}
		size, sn, ok := readSize(b[n:])
		if !ok {
			return
		}
		start := n + sn
		if size < 0 || int64(start)+size > int64(len(b)) {
			return
		}
		fn(id, b[start:start+int(size)])
		b = b[start+int(size):]
	}
}

func readID(b []byte) (uint32, int, bool) {
	if len(b) == 0 {
		return 0, 0, false
	}
	n := 1
	for mask := byte(0x80); n <= 4 && b[0]&mask == 0; mask >>= 1 {
		n++
	}
	if n > 4 || len(b) < n {
		return 0, 0, false
	}
	var id uint32
	for i := 0; i < n; i++ {
		id = id<<8 | uint32(b[i])
	}
	return id, n, true
}

// readSize returns -1 for an element of unknown size.
func readSize(b []byte) (int64, int, bool) {
	if len(b) == 0 {
		return 0, 0, false
	}
	n := 1
	mask := byte(0x80)
	for ; n <= 8 && b[0]&mask == 0; mask >>= 1 {
		n++
	}
	if n > 8 || len(b) < n {
		return 0, 0, false
	}
	value := uint64(b[0] & (mask - 1))
	ones := value == uint64(mask-1)
	for i := 1; i < n; i++ {
		value = value<<8 | uint64(b[i])
		ones = ones && b[i] == 0xFF
	}
	if ones {
		return -1, n, true
	}
	return int64(value), n, true
}

func readUint(b []byte) uint64 {
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v
}

func readFloat(b []byte) float64 {
	switch len(b) {
	case 4:
		return float64(math.Float32frombits(binary.BigEndian.Uint32(b)))
	case 8:
		return math.Float64frombits(binary.BigEndian.Uint64(b))
	}
	return 0
}
