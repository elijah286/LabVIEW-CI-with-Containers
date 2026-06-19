package viserver

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/color"
	"image/png"
)

// LVPictureData holds the fields of a LabVIEW picture cluster as returned by
// Get VI Info.vi. The cluster structure is:
//
//	[0] image type  (I32)
//	[1] image depth (I32)
//	[2] image       (Array[U8]) — raw pixel bytes, row-major
//	[3] mask        (Array[U8]) — transparency mask (1 bit/pixel packed)
//	[4] colors      (Array[U32]) — palette, each entry is 0x00RRGGBB
//	[5] rectangle   (Cluster{I16 left, I16 top, I16 right, I16 bottom})
type LVPictureData struct {
	ImageType  int32
	ImageDepth int32
	Image      []byte
	Mask       []byte
	Colors     []uint32
	Left       int16
	Top        int16
	Right      int16
	Bottom     int16
}

// ExtractPictureData converts the cluster map returned by unflattenFromTD for
// a Pict2 entry into a structured LVPictureData value.
func ExtractPictureData(cluster map[int]any) (*LVPictureData, error) {
	p := &LVPictureData{}

	// Field 0: image type (int32)
	if v, ok := cluster[0]; ok {
		switch t := v.(type) {
		case int32:
			p.ImageType = t
		default:
			return nil, fmt.Errorf("picture field 0 (image type): unexpected type %T", v)
		}
	}

	// Field 1: image depth (int32)
	if v, ok := cluster[1]; ok {
		switch t := v.(type) {
		case int32:
			p.ImageDepth = t
		default:
			return nil, fmt.Errorf("picture field 1 (image depth): unexpected type %T", v)
		}
	}

	// Field 2: image data ([]any of uint8 values)
	if v, ok := cluster[2]; ok {
		arr, ok := v.([]any)
		if !ok {
			return nil, fmt.Errorf("picture field 2 (image): unexpected type %T", v)
		}
		p.Image = make([]byte, len(arr))
		for i, elem := range arr {
			switch b := elem.(type) {
			case uint8:
				p.Image[i] = b
			default:
				return nil, fmt.Errorf("picture field 2 elem %d: unexpected type %T", i, elem)
			}
		}
	}

	// Field 3: mask data ([]any of uint8 values)
	if v, ok := cluster[3]; ok {
		arr, ok := v.([]any)
		if !ok {
			return nil, fmt.Errorf("picture field 3 (mask): unexpected type %T", v)
		}
		p.Mask = make([]byte, len(arr))
		for i, elem := range arr {
			switch b := elem.(type) {
			case uint8:
				p.Mask[i] = b
			default:
				return nil, fmt.Errorf("picture field 3 elem %d: unexpected type %T", i, elem)
			}
		}
	}

	// Field 4: colors palette ([]any of uint32 values)
	if v, ok := cluster[4]; ok {
		arr, ok := v.([]any)
		if !ok {
			return nil, fmt.Errorf("picture field 4 (colors): unexpected type %T", v)
		}
		p.Colors = make([]uint32, len(arr))
		for i, elem := range arr {
			switch c := elem.(type) {
			case uint32:
				p.Colors[i] = c
			default:
				return nil, fmt.Errorf("picture field 4 elem %d: unexpected type %T", i, elem)
			}
		}
	}

	// Field 5: rectangle cluster {left I16, top I16, right I16, bottom I16}
	if v, ok := cluster[5]; ok {
		rect, ok := v.(map[int]any)
		if !ok {
			return nil, fmt.Errorf("picture field 5 (rectangle): unexpected type %T", v)
		}
		if l, ok := rect[0].(int16); ok {
			p.Left = l
		}
		if t, ok := rect[1].(int16); ok {
			p.Top = t
		}
		if r, ok := rect[2].(int16); ok {
			p.Right = r
		}
		if b, ok := rect[3].(int16); ok {
			p.Bottom = b
		}
	}

	return p, nil
}

// Width returns the picture width in pixels.
func (p *LVPictureData) Width() int {
	return int(p.Right - p.Left)
}

// Height returns the picture height in pixels.
func (p *LVPictureData) Height() int {
	return int(p.Bottom - p.Top)
}

// ToPNG converts the LabVIEW picture data to a PNG-encoded byte slice.
// Returns nil if the picture is empty (no image data or zero dimensions).
func (p *LVPictureData) ToPNG() ([]byte, error) {
	w := p.Width()
	h := p.Height()
	if w <= 0 || h <= 0 || len(p.Image) == 0 {
		return nil, nil
	}

	if p.ImageDepth == 8 && len(p.Colors) > 0 {
		return p.toPNG8bpp(w, h)
	}
	if p.ImageDepth == 24 || p.ImageDepth == 32 {
		return p.toPNGDirect(w, h)
	}

	// Fallback for other depths: try 8bpp if palette exists.
	if len(p.Colors) > 0 {
		return p.toPNG8bpp(w, h)
	}
	return nil, fmt.Errorf("unsupported picture depth %d with %d palette entries", p.ImageDepth, len(p.Colors))
}

// ToBase64PNG converts to PNG and returns as base64-encoded string.
func (p *LVPictureData) ToBase64PNG() (string, error) {
	pngData, err := p.ToPNG()
	if err != nil {
		return "", err
	}
	if pngData == nil {
		return "", nil
	}
	return base64.StdEncoding.EncodeToString(pngData), nil
}

// toPNG8bpp handles 8-bit indexed color (palette mode).
func (p *LVPictureData) toPNG8bpp(w, h int) ([]byte, error) {
	// Build palette from colors array. LabVIEW stores colors as 0x00RRGGBB.
	palette := make(color.Palette, len(p.Colors))
	for i, c := range p.Colors {
		r := uint8((c >> 16) & 0xFF)
		g := uint8((c >> 8) & 0xFF)
		b := uint8(c & 0xFF)
		palette[i] = color.RGBA{R: r, G: g, B: b, A: 255}
	}

	img := image.NewPaletted(image.Rect(0, 0, w, h), palette)

	// Calculate stride: LabVIEW may pad rows. Determine actual stride from data.
	stride := len(p.Image) / h
	if stride < w {
		stride = w
	}

	for y := range h {
		rowStart := y * stride
		for x := range w {
			if rowStart+x < len(p.Image) {
				img.SetColorIndex(x, y, p.Image[rowStart+x])
			}
		}
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, fmt.Errorf("PNG encode: %w", err)
	}
	return buf.Bytes(), nil
}

// toPNGDirect handles 24-bit RGB or 32-bit RGBA/XRGB images.
func (p *LVPictureData) toPNGDirect(w, h int) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	bpp := int(p.ImageDepth) / 8
	stride := len(p.Image) / h
	if stride < w*bpp {
		stride = w * bpp
	}

	for y := range h {
		rowStart := y * stride
		for x := range w {
			off := rowStart + x*bpp
			if off+bpp > len(p.Image) {
				break
			}
			var r, g, b, a uint8
			switch bpp {
			case 3: // RGB
				r, g, b, a = p.Image[off], p.Image[off+1], p.Image[off+2], 255
			case 4: // XRGB or ARGB
				r, g, b, a = p.Image[off+1], p.Image[off+2], p.Image[off+3], 255
			}
			img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: a})
		}
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, fmt.Errorf("PNG encode: %w", err)
	}
	return buf.Bytes(), nil
}
