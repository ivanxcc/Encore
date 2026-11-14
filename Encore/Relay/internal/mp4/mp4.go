// Package mp4 reads an MP4 file's codecs over a few ranged reads, without downloading media: the
// top-level boxes are walked by their headers, and only the movie box (moov) is fetched.
package mp4

import (
	"context"
	"encoding/binary"
	"errors"
)

type Reader interface {
	ReadAt(ctx context.Context, off int64, n int) ([]byte, error)
}

type Track struct {
	Kind  string // "video", "audio", "other"
	Codec string // h264, hevc, av1, vp9, aac, ac3, eac3, opus, flac, mp3, alac, … or the raw four-character code
	// H.264 profile (avcC): 66 baseline, 77 main, 100 high, 110 high 10, …
	Profile int
}

type File struct {
	Duration float64
	Tracks   []Track
	// Fragmented: the samples are described in moof boxes along the file, not all in moov.
	Fragmented bool
}

var (
	ErrNotMP4 = errors.New("not an MP4 file")
	ErrNoMoov = errors.New("the MP4 has no movie box")
)

// Parse finds and reads moov. Typically one read for files prepared for streaming (moov first) and
// two or three for files with moov at the end.
func Parse(ctx context.Context, r Reader, size int64) (*File, error) {
	head, err := r.ReadAt(ctx, 0, 64<<10)
	if err != nil {
		return nil, err
	}
	if len(head) < 12 || string(head[4:8]) != "ftyp" {
		return nil, ErrNotMP4
	}
	var off int64
	buf, bufAt := head, int64(0)
	for i := 0; i < 64 && off+8 <= size; i++ {
		if off < bufAt || off+16 > bufAt+int64(len(buf)) {
			if buf, err = r.ReadAt(ctx, off, 16); err != nil {
				return nil, err
			}
			bufAt = off
		}
		b := buf[off-bufAt:]
		boxSize, kind, hdr := header(b)
		if boxSize == 0 {
			boxSize = size - off
		}
		if boxSize < int64(hdr) {
			return nil, ErrNoMoov
		}
		if kind == "moov" {
			if boxSize > 64<<20 {
				return nil, errors.New("the MP4's movie box is unreasonably large")
			}
			var moov []byte
			if off+boxSize <= bufAt+int64(len(buf)) {
				moov = buf[off-bufAt : off-bufAt+boxSize]
			} else if moov, err = r.ReadAt(ctx, off, int(boxSize)); err != nil {
				return nil, err
			}
			return parseMoov(moov[hdr:]), nil
		}
		off += boxSize
	}
	return nil, ErrNoMoov
}

func header(b []byte) (int64, string, int) {
	if len(b) < 8 {
		return -1, "", 8
	}
	size := int64(binary.BigEndian.Uint32(b))
	kind := string(b[4:8])
	if size == 1 && len(b) >= 16 {
		return int64(binary.BigEndian.Uint64(b[8:16])), kind, 16
	}
	return size, kind, 8
}

// children calls fn for each box directly inside b.
func children(b []byte, fn func(kind string, body []byte)) {
	for len(b) >= 8 {
		size, kind, hdr := header(b)
		if size == 0 {
			size = int64(len(b))
		}
		if size < int64(hdr) || size > int64(len(b)) {
			return
		}
		fn(kind, b[hdr:size])
		b = b[size:]
	}
}

func parseMoov(moov []byte) *File {
	f := &File{}
	children(moov, func(kind string, body []byte) {
		switch kind {
		case "mvhd":
			if len(body) >= 20 && body[0] == 0 {
				scale := binary.BigEndian.Uint32(body[12:16])
				if scale > 0 {
					f.Duration = float64(binary.BigEndian.Uint32(body[16:20])) / float64(scale)
				}
			} else if len(body) >= 32 {
				scale := binary.BigEndian.Uint32(body[20:24])
				if scale > 0 {
					f.Duration = float64(binary.BigEndian.Uint64(body[24:32])) / float64(scale)
				}
			}
		case "mvex":
			f.Fragmented = true
		case "trak":
			if t, ok := parseTrak(body); ok {
				f.Tracks = append(f.Tracks, t)
			}
		}
	})
	return f
}

func parseTrak(trak []byte) (Track, bool) {
	var t Track
	found := false
	children(trak, func(kind string, body []byte) {
		if kind != "mdia" {
			return
		}
		children(body, func(kind string, body []byte) {
			switch kind {
			case "hdlr":
				if len(body) >= 12 {
					switch string(body[8:12]) {
					case "vide":
						t.Kind = "video"
					case "soun":
						t.Kind = "audio"
					default:
						t.Kind = "other"
					}
				}
			case "minf":
				children(body, func(kind string, body []byte) {
					if kind != "stbl" {
						return
					}
					children(body, func(kind string, body []byte) {
						if kind != "stsd" || len(body) < 16 {
							return
						}
						entry := body[8:]
						size, format, _ := header(entry)
						t.Codec = codec(format)
						found = true
						if (format == "avc1" || format == "avc3") && size <= int64(len(entry)) && size > 86 {
							// The visual sample entry is 78 bytes after its header; avcC follows.
							children(entry[86:size], func(kind string, body []byte) {
								if kind == "avcC" && len(body) > 1 {
									t.Profile = int(body[1])
								}
							})
						}
					})
				})
			}
		})
	})
	return t, found
}

func codec(fourcc string) string {
	switch fourcc {
	case "avc1", "avc3":
		return "h264"
	case "hvc1", "hev1":
		return "hevc"
	case "av01":
		return "av1"
	case "vp09":
		return "vp9"
	case "mp4a":
		return "aac"
	case "ac-3":
		return "ac3"
	case "ec-3":
		return "eac3"
	case "Opus":
		return "opus"
	case "fLaC":
		return "flac"
	case ".mp3":
		return "mp3"
	case "alac":
		return "alac"
	case "dtsc", "dtsh", "dtsl", "dtse":
		return "dts"
	}
	return fourcc
}
