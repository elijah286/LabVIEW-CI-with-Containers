package viserver

// LabVIEW type flattening/unflattening.
//
// Implements the same wire encoding as LabVIEW's "Flatten To String" primitive.
// All multi-byte values are big-endian.

import (
	"encoding/binary"
	"fmt"
	"math"
	"runtime"
	"strings"
)

// PathValue marks a control value that should be sent as a LabVIEW path
// instead of a plain string.
type PathValue string

// ---------- Type codes (low byte of the int16 type word) ----------

const (
	tcVoid    uint16 = 0x00
	tcI8      uint16 = 0x01
	tcI16     uint16 = 0x02
	tcI32     uint16 = 0x03
	tcI64     uint16 = 0x04
	tcU8      uint16 = 0x05
	tcU16     uint16 = 0x06
	tcU32     uint16 = 0x07
	tcU64     uint16 = 0x08
	tcSGL     uint16 = 0x09 // float32
	tcDBL     uint16 = 0x0A // float64
	tcEXT     uint16 = 0x0B // extended (not supported in Go)
	tcCSG     uint16 = 0x0C // complex single
	tcCDB     uint16 = 0x0D // complex double
	tcCXT     uint16 = 0x0E // complex extended
	tcEnum8   uint16 = 0x15
	tcEnum16  uint16 = 0x16
	tcEnum32  uint16 = 0x17
	tcBoolU16 uint16 = 0x20 // old boolean (pre-8.0)
	tcBool    uint16 = 0x21 // boolean U8
	tcString  uint16 = 0x30
	tcPath    uint16 = 0x32
	tcPicture uint16 = 0x3C // LabVIEW picture/pixmap
	tcArray   uint16 = 0x40
	tcCluster uint16 = 0x50
	tcVariant uint16 = 0x53
	tcPict2   uint16 = 0xF1 // Extended picture type (2D picture data)
)

// ---------- Flatten Go values → bytes ----------

// flattenValue writes a Go value as LabVIEW flattened data.
// Returns (typeDescriptor, flatData, error).
func flattenValue(v any) ([]byte, []byte, error) {
	switch val := v.(type) {
	case bool:
		td := makeTDSimple(tcBool)
		d := byte(0)
		if val {
			d = 1
		}
		return td, []byte{d}, nil

	case int8:
		return makeTDSimple(tcI8), []byte{byte(val)}, nil
	case int16:
		td := makeTDSimple(tcI16)
		b := make([]byte, 2)
		be.PutUint16(b, uint16(val))
		return td, b, nil
	case int32:
		td := makeTDSimple(tcI32)
		b := make([]byte, 4)
		be.PutUint32(b, uint32(val))
		return td, b, nil
	case int:
		td := makeTDSimple(tcI32)
		b := make([]byte, 4)
		be.PutUint32(b, uint32(int32(val)))
		return td, b, nil
	case int64:
		td := makeTDSimple(tcI64)
		b := make([]byte, 8)
		be.PutUint64(b, uint64(val))
		return td, b, nil

	case uint8:
		return makeTDSimple(tcU8), []byte{val}, nil
	case uint16:
		td := makeTDSimple(tcU16)
		b := make([]byte, 2)
		be.PutUint16(b, val)
		return td, b, nil
	case uint32:
		td := makeTDSimple(tcU32)
		b := make([]byte, 4)
		be.PutUint32(b, val)
		return td, b, nil
	case uint64:
		td := makeTDSimple(tcU64)
		b := make([]byte, 8)
		be.PutUint64(b, val)
		return td, b, nil

	case float32:
		td := makeTDSimple(tcSGL)
		b := make([]byte, 4)
		be.PutUint32(b, math.Float32bits(val))
		return td, b, nil
	case float64:
		td := makeTDSimple(tcDBL)
		b := make([]byte, 8)
		be.PutUint64(b, math.Float64bits(val))
		return td, b, nil

	case string:
		td := makeTDString()
		b := make([]byte, 4+len(val))
		be.PutUint32(b, uint32(len(val)))
		copy(b[4:], val)
		return td, b, nil

	case PathValue:
		td := makeTDSimple(tcPath)
		b, err := flattenVIPath(string(val))
		if err != nil {
			return nil, nil, err
		}
		return td, b, nil

	case []byte:
		td := makeTDString()
		b := make([]byte, 4+len(val))
		be.PutUint32(b, uint32(len(val)))
		copy(b[4:], val)
		return td, b, nil

	default:
		return nil, nil, fmt.Errorf("unsupported Go type for flatten: %T", v)
	}
}

// flattenData flattens just the data portion (no type descriptor) for a known type.
func flattenData(v any) ([]byte, error) {
	_, d, err := flattenValue(v)
	return d, err
}

// ---------- Unflatten bytes → Go values ----------

// unflattenData reads a single value from buf given its type code.
// Returns (value, bytesConsumed, error).
func unflattenData(tc uint16, buf []byte) (any, int, error) {
	switch tc {
	case tcBool:
		if len(buf) < 1 {
			return nil, 0, fmt.Errorf("bool: need 1 byte")
		}
		return buf[0] != 0, 1, nil

	case tcI8:
		if len(buf) < 1 {
			return nil, 0, nil
		}
		return int8(buf[0]), 1, nil
	case tcI16:
		if len(buf) < 2 {
			return nil, 0, fmt.Errorf("i16: need 2 bytes")
		}
		return int16(be.Uint16(buf)), 2, nil
	case tcI32:
		if len(buf) < 4 {
			return nil, 0, fmt.Errorf("i32: need 4 bytes")
		}
		return int32(be.Uint32(buf)), 4, nil
	case tcI64:
		if len(buf) < 8 {
			return nil, 0, fmt.Errorf("i64: need 8 bytes")
		}
		return int64(be.Uint64(buf)), 8, nil

	case tcU8:
		if len(buf) < 1 {
			return nil, 0, nil
		}
		return buf[0], 1, nil
	case tcU16, tcEnum16:
		if len(buf) < 2 {
			return nil, 0, fmt.Errorf("u16: need 2 bytes")
		}
		return be.Uint16(buf), 2, nil
	case tcU32, tcEnum32:
		if len(buf) < 4 {
			return nil, 0, fmt.Errorf("u32: need 4 bytes")
		}
		return be.Uint32(buf), 4, nil
	case tcU64:
		if len(buf) < 8 {
			return nil, 0, fmt.Errorf("u64: need 8 bytes")
		}
		return be.Uint64(buf), 8, nil

	case tcSGL:
		if len(buf) < 4 {
			return nil, 0, fmt.Errorf("sgl: need 4 bytes")
		}
		return math.Float32frombits(be.Uint32(buf)), 4, nil
	case tcDBL:
		if len(buf) < 8 {
			return nil, 0, fmt.Errorf("dbl: need 8 bytes")
		}
		return math.Float64frombits(be.Uint64(buf)), 8, nil

	case tcString:
		if len(buf) < 4 {
			return nil, 0, fmt.Errorf("string: need length prefix")
		}
		n := int(be.Uint32(buf))
		if len(buf) < 4+n {
			return nil, 0, fmt.Errorf("string: need %d bytes, have %d", 4+n, len(buf))
		}
		return string(buf[4 : 4+n]), 4 + n, nil

	case tcPath:
		return unflattenPath(buf)

	case tcPicture, tcPict2:
		// Picture types are stored as length-prefixed byte arrays, same as strings.
		if len(buf) < 4 {
			return nil, 0, fmt.Errorf("picture: need length prefix")
		}
		n := int(be.Uint32(buf))
		if len(buf) < 4+n {
			return nil, 0, fmt.Errorf("picture: need %d bytes, have %d", 4+n, len(buf))
		}
		data := make([]byte, n)
		copy(data, buf[4:4+n])
		return data, 4 + n, nil

	case tcBoolU16:
		if len(buf) < 2 {
			return nil, 0, fmt.Errorf("boolU16: need 2 bytes")
		}
		return be.Uint16(buf) != 0, 2, nil

	default:
		return nil, 0, fmt.Errorf("unsupported type code 0x%04X for unflatten", tc)
	}
}

func unflattenPath(buf []byte) (any, int, error) {
	if len(buf) < 8 {
		return nil, 0, fmt.Errorf("path: need header")
	}
	code := string(buf[:4])
	payloadLen := int(be.Uint32(buf[4:8]))
	if len(buf) < 8+payloadLen {
		return nil, 0, fmt.Errorf("path: payload truncated")
	}
	payload := buf[8 : 8+payloadLen]

	switch code {
	case flatPathCodePTH2:
		if len(payload) < 4 {
			return nil, 0, fmt.Errorf("path: PTH2 payload too short")
		}
		subcode := string(payload[:4])
		parts := make([]string, 0)
		for off := 4; off < len(payload); {
			if off+2 > len(payload) {
				return nil, 0, fmt.Errorf("path: PTH2 component truncated")
			}
			n := int(be.Uint16(payload[off:]))
			off += 2
			if off+n > len(payload) {
				return nil, 0, fmt.Errorf("path: PTH2 component payload truncated")
			}
			parts = append(parts, string(payload[off:off+n]))
			off += n
		}
		path := strings.Join(parts, "/")
		if subcode == flatPathAbsSub {
			path = "/" + path
		}
		return path, 8 + payloadLen, nil
	case flatPathCodePTH0:
		if len(payload) < 4 {
			return nil, 0, fmt.Errorf("path: PTH0 payload too short")
		}
		pathType := int16(be.Uint16(payload[:2]))
		nParts := int(be.Uint16(payload[2:4]))
		parts := make([]string, 0, nParts)
		off := 4
		for i := 0; i < nParts; i++ {
			if off >= len(payload) {
				return nil, 0, fmt.Errorf("path: PTH0 component truncated")
			}
			n := int(payload[off])
			off++
			if off+n > len(payload) {
				return nil, 0, fmt.Errorf("path: PTH0 component payload truncated")
			}
			parts = append(parts, string(payload[off:off+n]))
			off += n
		}

		var path string
		switch pathType {
		case oldPathTypeAbs:
			if runtime.GOOS == "windows" {
				// Windows: reconstruct as drive letter path (e.g., "C:\foo\bar")
				if len(parts) == 0 {
					path = ""
				} else {
					path = parts[0] + ":"
					if len(parts) > 1 {
						path += "\\" + strings.Join(parts[1:], "\\")
					}
				}
			} else {
				// macOS/Linux: reconstruct as Unix path (e.g., "/Users/foo/bar")
				path = "/" + strings.Join(parts, "/")
			}
		case oldPathTypeRel:
			if runtime.GOOS == "windows" {
				path = strings.Join(parts, "\\")
			} else {
				path = strings.Join(parts, "/")
			}
		case oldPathTypeUNC:
			path = "\\\\" + strings.Join(parts, "\\")
		default:
			return nil, 0, fmt.Errorf("path: unsupported PTH0 path type %d", pathType)
		}
		return path, 8 + payloadLen, nil
	default:
		return nil, 0, fmt.Errorf("path: unsupported path code %q", code)
	}
}

// ---------- Simple type descriptor builders ----------

const (
	tdCodeVoid     uint16 = 0x00
	tdCodeI8       uint16 = 0x01
	tdCodeI16      uint16 = 0x02
	tdCodeI32      uint16 = 0x03
	tdCodeI64      uint16 = 0x04
	tdCodeU8       uint16 = 0x05
	tdCodeU16      uint16 = 0x06
	tdCodeU32      uint16 = 0x07
	tdCodeU64      uint16 = 0x08
	tdCodeSGL      uint16 = 0x09
	tdCodeDBL      uint16 = 0x0A
	tdCodeBool     uint16 = 0x21
	tdCodeString   uint16 = 0x30
	tdCodePath     uint16 = 0x32
	tdCodeVariant  uint16 = 0x53
	tdStringVarLen int32  = -1
)

// VI Server PutTypeDescriptor uses tdcore's saved-TD format for one type:
//
//	U32 nTDs (=1)
//	varsize tdSize
//	I16 typeCode
//	... type-specific payload
//	varsize typeListSize (=1)
//	varsize typeRef (=0)
//
// This matches FlattenOneType/FlattenListOfTypes in TD80ReadWrite.cpp.
func appendVarSizeField(dst []byte, v int32) []byte {
	if v >= 0x8000 {
		return binary.BigEndian.AppendUint32(dst, uint32(v)|0x80000000)
	}
	return binary.BigEndian.AppendUint16(dst, uint16(v))
}

func appendI32(dst []byte, v int32) []byte {
	return binary.BigEndian.AppendUint32(dst, uint32(v))
}

func makeSavedTD(typeCode uint16, payload []byte) []byte {
	var out []byte
	out = binary.BigEndian.AppendUint32(out, 1)
	out = appendVarSizeField(out, int32(4+len(payload)))
	out = binary.BigEndian.AppendUint16(out, typeCode)
	out = append(out, payload...)
	out = appendVarSizeField(out, 1)
	out = appendVarSizeField(out, 0)
	return out
}

func makeTDSimple(tc uint16) []byte {
	switch tc {
	case tcVoid:
		return makeSavedTD(tdCodeVoid, nil)
	case tcI8:
		return makeSavedTD(tdCodeI8, nil)
	case tcI16:
		return makeSavedTD(tdCodeI16, nil)
	case tcI32:
		return makeSavedTD(tdCodeI32, nil)
	case tcI64:
		return makeSavedTD(tdCodeI64, nil)
	case tcU8:
		return makeSavedTD(tdCodeU8, nil)
	case tcU16:
		return makeSavedTD(tdCodeU16, nil)
	case tcU32:
		return makeSavedTD(tdCodeU32, nil)
	case tcU64:
		return makeSavedTD(tdCodeU64, nil)
	case tcSGL:
		return makeSavedTD(tdCodeSGL, nil)
	case tcDBL:
		return makeSavedTD(tdCodeDBL, nil)
	case tcBool:
		return makeSavedTD(tdCodeBool, nil)
	case tcPath:
		return makeSavedTD(tdCodePath, appendI32(nil, tdStringVarLen))
	case tcVariant:
		return makeSavedTD(tdCodeVariant, nil)
	default:
		panic(fmt.Sprintf("unsupported saved TD type 0x%04X", tc))
	}
}

// makeTDString builds the saved-TD encoding for a variable-length string.
func makeTDString() []byte {
	return makeSavedTD(tdCodeString, appendI32(nil, tdStringVarLen))
}

// makeTDVariant builds the saved-TD encoding for a LabVIEW variant.
func makeTDVariant() []byte {
	return makeTDSimple(tcVariant)
}

// ---------- Exported TD builders for use by test/diagnostic scripts ----------

// TDString returns the saved-TD encoding for a variable-length string.
func TDString() []byte { return makeTDString() }

// TDPath returns the saved-TD encoding for a LabVIEW path.
func TDPath() []byte { return makeTDSimple(tcPath) }

// TDI32 returns the saved-TD encoding for a 32-bit signed integer.
func TDI32() []byte { return makeTDSimple(tcI32) }

// TDBool returns the saved-TD encoding for a boolean.
func TDBool() []byte { return makeTDSimple(tcBool) }

// TDVariant returns the saved-TD encoding for a variant.
func TDVariant() []byte { return makeTDVariant() }

// ---------- Compound TD builders ----------

// makeTDPathArray builds the saved-TD encoding for a 1D array of paths.
// FlatTDR format:
//
//	U32 nEntries (=2)
//	Entry 0: Path   — entryLen=8, typeCode=0x32, payload=I32(-1)
//	Entry 1: Array  — entryLen=12, typeCode=0x40, payload=I16(1)+I32(0)+I16(0)
//	U16 typeListCount (=1)
//	U16 rootIdx (=1, the array entry)
func makeTDPathArray() []byte {
	var out []byte
	// nEntries = 2
	out = binary.BigEndian.AppendUint32(out, 2)

	// Entry 0: Path (tcPath = 0x32) with variable length
	// entryLen = 4 (overhead: 2 entryLen + 2 typeCode) + 4 (I32 varLen) = 8
	out = binary.BigEndian.AppendUint16(out, 8)     // entryLen
	out = binary.BigEndian.AppendUint16(out, 0x32)  // typeCode = tcPath
	out = binary.BigEndian.AppendUint32(out, 0xFFFFFFFF) // I32(-1) = variable length

	// Entry 1: Array (tcArray = 0x40), 1D, element index = 0
	// entryLen = 4 (overhead) + 2 (nDims) + 4 (dimSize[0]) + 2 (elemIdx) = 12
	out = binary.BigEndian.AppendUint16(out, 12)    // entryLen
	out = binary.BigEndian.AppendUint16(out, 0x40)  // typeCode = tcArray
	out = binary.BigEndian.AppendUint16(out, 1)     // nDims = 1
	out = binary.BigEndian.AppendUint32(out, 0xFFFFFFFF) // dimSize[0] = -1 (kVblDimSz, variable-length)
	out = binary.BigEndian.AppendUint16(out, 0)     // elemIdx = 0 (Path entry)

	// Type list: count=1, rootIdx=1 (the Array entry is the root type)
	out = binary.BigEndian.AppendUint16(out, 1) // typeListCount
	out = binary.BigEndian.AppendUint16(out, 1) // rootIdx

	return out
}

// flattenPathArray flattens a slice of path strings into LabVIEW wire format
// for a 1D array of paths: I32(count) + flattened path data for each element.
func flattenPathArray(paths []string) ([]byte, error) {
	var buf []byte
	buf = binary.BigEndian.AppendUint32(buf, uint32(len(paths)))
	for _, p := range paths {
		flat, err := flattenVIPath(p)
		if err != nil {
			return nil, fmt.Errorf("flatten path %q: %w", p, err)
		}
		buf = append(buf, flat...)
	}
	return buf, nil
}

// unflattenPathArray parses a 1D array of paths from LabVIEW wire format.
func unflattenPathArray(buf []byte) ([]string, error) {
	if len(buf) < 4 {
		return nil, fmt.Errorf("path array: need length prefix")
	}
	count := int(binary.BigEndian.Uint32(buf))
	off := 4
	paths := make([]string, 0, count)
	for i := 0; i < count; i++ {
		if off >= len(buf) {
			return nil, fmt.Errorf("path array: truncated at element %d", i)
		}
		val, n, err := unflattenPath(buf[off:])
		if err != nil {
			return nil, fmt.Errorf("path array element %d: %w", i, err)
		}
		if s, ok := val.(string); ok {
			paths = append(paths, s)
		} else {
			paths = append(paths, fmt.Sprintf("%v", val))
		}
		off += n
	}
	return paths, nil
}
