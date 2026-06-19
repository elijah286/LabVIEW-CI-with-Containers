package viserver

import (
	"bytes"
	"encoding/binary"
	"fmt"
	pathpkg "path"
	"runtime"
	"strings"
	"unicode"
)

const (
	flatPathCodePTH2 = "PTH2"
	flatPathCodePTH0 = "PTH0"
	flatPathAbsSub   = "abs "
	flatPathRelSub   = "rel "
	flatPathUNCSub   = "unc "

	oldPathTypeAbs = int16(0)
	oldPathTypeRel = int16(1)
	oldPathTypeUNC = int16(3)
)

func flattenVIPath(path string) ([]byte, error) {
	if path == "" {
		return nil, fmt.Errorf("empty path")
	}

	if runtime.GOOS == "windows" {
		if looksLikeUnixAbsolutePath(path) {
			return nil, fmt.Errorf("unix-style absolute paths are not supported on Windows: %q", path)
		}
		clean, err := cleanWindowsPath(path)
		if err != nil {
			return nil, err
		}
		return flattenWindowsPath(clean)
	}

	if looksLikeWindowsPath(path) {
		return nil, fmt.Errorf("windows-style paths are not supported on %s: %q", runtime.GOOS, path)
	}

	clean := cleanUnixPath(path)
	if clean == "." || clean == "" {
		return nil, fmt.Errorf("empty path")
	}

	return flattenUnixPath(clean)
}

func looksLikeUnixAbsolutePath(path string) bool {
	return strings.HasPrefix(path, "/")
}

func looksLikeWindowsPath(path string) bool {
	if len(path) >= 2 && path[0] == '\\' && path[1] == '\\' {
		return true
	}
	if len(path) >= 2 && unicode.IsLetter(rune(path[0])) && path[1] == ':' {
		return true
	}
	return false
}

func cleanUnixPath(path string) string {
	return pathpkg.Clean(path)
}

func cleanWindowsPath(path string) (string, error) {
	normalized := strings.ReplaceAll(path, "/", `\`)
	if normalized == "" {
		return "", fmt.Errorf("empty path")
	}

	root := ""
	rest := normalized
	switch {
	case strings.HasPrefix(normalized, `\\`):
		rest = strings.TrimPrefix(normalized, `\\`)
		parts := splitWindowsRawParts(rest)
		if len(parts) < 2 {
			return "", fmt.Errorf("invalid UNC path %q", path)
		}
		root = `\\` + parts[0] + `\` + parts[1]
		rest = strings.Join(parts[2:], `\`)
	case len(normalized) >= 2 && unicode.IsLetter(rune(normalized[0])) && normalized[1] == ':':
		root = normalized[:2]
		rest = strings.TrimPrefix(normalized[2:], `\`)
	}

	cleanParts := collapseWindowsParts(splitWindowsRawParts(rest))
	switch {
	case strings.HasPrefix(root, `\\`):
		if len(cleanParts) == 0 {
			return root, nil
		}
		return root + `\` + strings.Join(cleanParts, `\`), nil
	case root != "":
		if len(cleanParts) == 0 {
			return root + `\`, nil
		}
		return root + `\` + strings.Join(cleanParts, `\`), nil
	case len(cleanParts) == 0:
		return ".", nil
	default:
		return strings.Join(cleanParts, `\`), nil
	}
}

func splitWindowsRawParts(path string) []string {
	if path == "" {
		return nil
	}
	raw := strings.Split(path, `\`)
	parts := make([]string, 0, len(raw))
	for _, part := range raw {
		if part == "" {
			continue
		}
		parts = append(parts, part)
	}
	return parts
}

func collapseWindowsParts(parts []string) []string {
	stack := make([]string, 0, len(parts))
	for _, part := range parts {
		switch part {
		case "", ".":
			continue
		case "..":
			if len(stack) > 0 && stack[len(stack)-1] != ".." {
				stack = stack[:len(stack)-1]
				continue
			}
		}
		stack = append(stack, part)
	}
	return stack
}

func flattenUnixPath(path string) ([]byte, error) {
	if path == "/" {
		return makePTH2(flatPathAbsSub, nil), nil
	}

	abs := strings.HasPrefix(path, "/")
	trimmed := strings.TrimPrefix(path, "/")
	parts := splitPathParts(trimmed)
	if abs {
		return makePTH2(flatPathAbsSub, parts), nil
	}
	return makePTH2(flatPathRelSub, parts), nil
}

func flattenWindowsPath(path string) ([]byte, error) {
	normalized := strings.ReplaceAll(path, `\`, "/")
	if strings.HasPrefix(normalized, "//") {
		parts := splitPathParts(strings.TrimPrefix(normalized, "//"))
		return makePTH0(oldPathTypeUNC, parts), nil
	}

	if len(normalized) >= 2 && normalized[1] == ':' {
		vol := normalized[:2]
		trimmed := strings.TrimPrefix(normalized[2:], "/")
		parts := append([]string{strings.TrimSuffix(vol, ":")}, splitPathParts(trimmed)...)
		return makePTH0(oldPathTypeAbs, parts), nil
	}

	return makePTH0(oldPathTypeRel, splitPathParts(normalized)), nil
}

func splitPathParts(path string) []string {
	if path == "" {
		return nil
	}
	raw := strings.Split(path, "/")
	parts := make([]string, 0, len(raw))
	for _, part := range raw {
		if part == "" || part == "." {
			continue
		}
		parts = append(parts, part)
	}
	return parts
}

func makePTH2(subcode string, parts []string) []byte {
	var payload bytes.Buffer
	payload.WriteString(subcode)
	for _, part := range parts {
		b := []byte(part)
		_ = binary.Write(&payload, be, int16(len(b)))
		payload.Write(b)
	}

	var out bytes.Buffer
	out.WriteString(flatPathCodePTH2)
	_ = binary.Write(&out, be, int32(payload.Len()))
	out.Write(payload.Bytes())
	return out.Bytes()
}

func makePTH0(pathType int16, parts []string) []byte {
	var payload bytes.Buffer
	_ = binary.Write(&payload, be, pathType)
	_ = binary.Write(&payload, be, int16(len(parts)))
	for _, part := range parts {
		b := []byte(part)
		if len(b) > 255 {
			b = b[:255]
		}
		payload.WriteByte(byte(len(b)))
		payload.Write(b)
	}
	if payload.Len()%2 != 0 {
		payload.WriteByte(0)
	}

	var out bytes.Buffer
	out.WriteString(flatPathCodePTH0)
	_ = binary.Write(&out, be, int32(payload.Len()))
	out.Write(payload.Bytes())
	return out.Bytes()
}
