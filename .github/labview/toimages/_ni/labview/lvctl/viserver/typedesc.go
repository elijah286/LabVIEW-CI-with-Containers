package viserver

// Type descriptor parsing for responses received from VI Server.
//
// When the server sends back property values or call results, the data is
// preceded by a FlatTDR (type descriptor) that tells us how to interpret the
// bytes. This file decodes that descriptor so unflatten can pick the right
// reader.

import (
	"fmt"
)

// tdEntry is a single entry in the type descriptor table.
type tdEntry struct {
	typeCode uint16
	// For arrays: number of dimensions.
	nDims int
	// For arrays: index of element type in the TD table.
	elemIdx int
	// For clusters: indices of element types in the TD table.
	fieldIdxs []int
	// For strings: declared length (-1 = variable).
	strLen int32
	// Name of the entry (if the named flag 0x40 is set in the type code high byte).
	name string
}

// parseFlatTDR decodes a FlatTDR blob (new-style, LV >= 8.0) and returns the
// root type code plus the full entry table.
func parseFlatTDR(buf []byte) ([]tdEntry, int, error) {
	entries, rootIdx, _, err := parseFlatTDRWithSize(buf)
	return entries, rootIdx, err
}

func parseFlatTDRWithSize(buf []byte) ([]tdEntry, int, int, error) {
	if len(buf) < 4 {
		return nil, 0, 0, fmt.Errorf("FlatTDR too short for entry count")
	}
	nEntries := int(int32(be.Uint32(buf)))
	off := 4

	entries := make([]tdEntry, nEntries)
	for i := range nEntries {
		if off+4 > len(buf) {
			return nil, 0, 0, fmt.Errorf("FlatTDR truncated at entry %d", i)
		}
		entryLen := int(int16(be.Uint16(buf[off:])))
		tc := be.Uint16(buf[off+2:])
		entries[i].typeCode = tc & 0x00FF // mask off flags

		// Type-specific data starts immediately after entryLen + typeCode.
		// Named entries (flag 0x40 in high byte of tc) have a Pascal-style
		// name string appended AFTER the type-specific data at the end of
		// the entry. We extract the name from the entry tail.
		pos := off + 4

		switch entries[i].typeCode {
		case tcString:
			if pos+4 <= off+entryLen {
				entries[i].strLen = int32(be.Uint32(buf[pos:]))
			} else {
				entries[i].strLen = -1
			}

		case tcArray:
			// Layout: int16 nDims, int32 dimSize[nDims], int16 elemIdx, [name]
			if pos+2 > len(buf) {
				break
			}
			nDims := int(int16(be.Uint16(buf[pos:])))
			entries[i].nDims = nDims
			pos += 2
			pos += nDims * 4 // skip dimension sizes (int32 each)
			if pos+2 <= len(buf) {
				entries[i].elemIdx = int(int16(be.Uint16(buf[pos:])))
			}

		case tcCluster:
			// Layout: int16 nFields, int16 fieldIdx[nFields], [name]
			if pos+2 > len(buf) {
				break
			}
			nFields := int(int16(be.Uint16(buf[pos:])))
			pos += 2
			for j := range nFields {
				_ = j
				if pos+2 > len(buf) {
					break
				}
				idx := int(int16(be.Uint16(buf[pos:])))
				entries[i].fieldIdxs = append(entries[i].fieldIdxs, idx)
				pos += 2
			}

		case tcPict2:
			// Pict2 (0xF1) entries embed a cluster type descriptor describing
			// the picture data structure. Format within the entry:
			//   8 bytes: metadata
			//   Pascal string: control type name (1 byte len + chars)
			//   embedded cluster entry: [entryLen, typeCode, nFields, fieldIdx...]
			// We scan for the embedded cluster (tc 0x4050 or 0x0050) and
			// extract its field indices so we can unflatten as a cluster.
			entryEnd := off + entryLen
			// Skip 8 bytes of metadata.
			pos += 8
			if pos >= entryEnd {
				break
			}
			// Skip Pascal string for control type name.
			ctrlNameLen := int(buf[pos])
			pos += 1 + ctrlNameLen
			// Align to even boundary.
			if pos%2 != 0 {
				pos++
			}
			// Now we should be at the embedded entry: entryLen + typeCode + ...
			if pos+4 > entryEnd {
				break
			}
			// Skip the embedded entryLen.
			pos += 2
			// Read embedded typeCode (should be cluster 0x50 or 0x4050).
			embTC := be.Uint16(buf[pos:])
			pos += 2
			if embTC&0x00FF == tcCluster && pos+2 <= entryEnd {
				nFields := int(int16(be.Uint16(buf[pos:])))
				pos += 2
				for j := range nFields {
					_ = j
					if pos+2 > entryEnd {
						break
					}
					idx := int(int16(be.Uint16(buf[pos:])))
					entries[i].fieldIdxs = append(entries[i].fieldIdxs, idx)
					pos += 2
				}
			}
		}

		// Extract name from the end of the entry if the named flag is set.
		if tc&0x4000 != 0 {
			// The name is a Pascal string at the end of the entry:
			// [1 byte nameLen] [nameLen chars] [optional pad to even]
			// We find it by scanning from the current pos to the entry end.
			nameStart := pos
			entryEnd := off + entryLen
			if nameStart < entryEnd {
				nameLen := int(buf[nameStart])
				if nameLen > 0 && nameStart+1+nameLen <= entryEnd {
					entries[i].name = string(buf[nameStart+1 : nameStart+1+nameLen])
				}
			}
		}

		off += entryLen
	}

	// After entries: type list count + root index.
	rootIdx := 0
	if off+4 <= len(buf) {
		// typeListCount := int(int16(be.Uint16(buf[off:])))
		rootIdx = int(int16(be.Uint16(buf[off+2:])))
		off += 4
	}

	return entries, rootIdx, off, nil
}

// readVariableSizeField reads a variable-size field used in TD serialization.
// If the high bit of the first int16 is set, it's a 32-bit value.
func readVariableSizeField(buf []byte) (int, int) {
	if len(buf) < 2 {
		return 0, 0
	}
	v := int16(be.Uint16(buf))
	if v >= 0 {
		return int(v), 2
	}
	// High bit set — 32-bit value.
	if len(buf) < 4 {
		return int(v & 0x7FFF), 2
	}
	hi := uint32(be.Uint16(buf)) & 0x7FFF
	lo := uint32(be.Uint16(buf[2:]))
	return int((hi << 16) | lo), 4
}

// unflattenFromTD reads flattened data using a parsed type descriptor table.
func unflattenFromTD(entries []tdEntry, idx int, buf []byte) (any, int, error) {
	if idx < 0 || idx >= len(entries) {
		return nil, 0, fmt.Errorf("TD index %d out of range", idx)
	}
	e := entries[idx]

	switch e.typeCode {
	case tcArray:
		if len(buf) < e.nDims*4 {
			return nil, 0, fmt.Errorf("array: need dimension sizes")
		}
		totalElems := 1
		off := 0
		for range e.nDims {
			dimSz := int(int32(be.Uint32(buf[off:])))
			totalElems *= dimSz
			off += 4
		}
		result := make([]any, totalElems)
		for i := range totalElems {
			v, n, err := unflattenFromTD(entries, e.elemIdx, buf[off:])
			if err != nil {
				return nil, 0, fmt.Errorf("array elem %d: %w", i, err)
			}
			result[i] = v
			off += n
		}
		return result, off, nil

	case tcCluster:
		result := make(map[int]any, len(e.fieldIdxs))
		off := 0
		for i, fIdx := range e.fieldIdxs {
			v, n, err := unflattenFromTD(entries, fIdx, buf[off:])
			if err != nil {
				return nil, 0, fmt.Errorf("cluster field %d: %w", i, err)
			}
			result[i] = v
			off += n
		}
		return result, off, nil

	case tcPict2:
		// Pict2 entries have an embedded cluster structure parsed during TD
		// parsing. Unflatten the data as that cluster.
		if len(e.fieldIdxs) == 0 {
			// Fallback: treat as opaque length-prefixed blob.
			return unflattenData(e.typeCode, buf)
		}
		result := make(map[int]any, len(e.fieldIdxs))
		off := 0
		for i, fIdx := range e.fieldIdxs {
			v, n, err := unflattenFromTD(entries, fIdx, buf[off:])
			if err != nil {
				return nil, 0, fmt.Errorf("picture field %d: %w", i, err)
			}
			result[i] = v
			off += n
		}
		return result, off, nil

	default:
		// Delegate to the simple scalar unflatten.
		return unflattenData(e.typeCode, buf)
	}
}
