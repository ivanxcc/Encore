// Package hls turns an indexed Matroska file into an HLS stream whose every segment can be made on
// its own. The playlist is written before any media is read, from the file's keyframe index, so a
// seek anywhere costs one segment, never a restart.
package hls

import (
	"fmt"
	"math"
	"strings"

	"encore/relay/internal/mkv"
)

// Plan is the fixed layout of a stream: where each segment starts in time and in the file.
type Plan struct {
	Starts   []float64
	Offsets  []int64
	Duration float64
}

// TargetSeconds is the shortest a segment may be; segments end on the next keyframe after it.
const TargetSeconds = 4.0

func NewPlan(f *mkv.File) Plan {
	var p Plan
	p.Duration = f.Duration
	for _, c := range f.Cues {
		if len(p.Starts) == 0 || c.Time-p.Starts[len(p.Starts)-1] >= TargetSeconds-0.001 {
			p.Starts = append(p.Starts, c.Time)
			p.Offsets = append(p.Offsets, c.Offset)
		}
	}
	return p
}

func (p Plan) Count() int { return len(p.Starts) }

func (p Plan) Length(i int) float64 {
	end := p.Duration
	if i+1 < len(p.Starts) {
		end = p.Starts[i+1]
	}
	return math.Max(0.05, end-p.Starts[i])
}

// At is the segment that contains a time.
func (p Plan) At(seconds float64) int {
	i := 0
	for i+1 < len(p.Starts) && p.Starts[i+1] <= seconds {
		i++
	}
	return i
}

// boundary is the segment that starts at a time (within a frame's tolerance), or -1.
func (p Plan) boundary(seconds float64) int {
	lo, hi := 0, len(p.Starts)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		switch d := p.Starts[mid] - seconds; {
		case math.Abs(d) <= 0.012:
			return mid
		case d < 0:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return -1
}

// Playlist is the complete VOD playlist.
func (p Plan) Playlist() string {
	longest := 1.0
	for i := range p.Starts {
		longest = math.Max(longest, p.Length(i))
	}
	var b strings.Builder
	b.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n")
	fmt.Fprintf(&b, "#EXT-X-TARGETDURATION:%d\n", int(math.Ceil(longest)))
	b.WriteString("#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n")
	for i := range p.Starts {
		fmt.Fprintf(&b, "#EXTINF:%.3f,\nseg/%d.ts\n", p.Length(i), i)
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	return b.String()
}
