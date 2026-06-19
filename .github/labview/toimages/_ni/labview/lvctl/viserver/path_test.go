package viserver

import (
	"encoding/binary"
	"runtime"
	"strings"
	"testing"
)

func TestFlattenVIPathUsesLocalOSPathRules(t *testing.T) {
	if runtime.GOOS == "windows" {
		flat, err := flattenVIPath(`C:\work\..\Convert.vi`)
		if err != nil {
			t.Fatalf("flattenVIPath() error = %v", err)
		}
		if got := string(flat[:4]); got != flatPathCodePTH0 {
			t.Fatalf("magic = %q, want %q", got, flatPathCodePTH0)
		}
		return
	}

	flat, err := flattenVIPath("/tmp/../Convert.vi")
	if err != nil {
		t.Fatalf("flattenVIPath() error = %v", err)
	}
	if got := string(flat[:4]); got != flatPathCodePTH2 {
		t.Fatalf("magic = %q, want %q", got, flatPathCodePTH2)
	}
}

func TestFlattenVIPathRejectsForeignAbsolutePaths(t *testing.T) {
	var foreignPath string
	if runtime.GOOS == "windows" {
		foreignPath = "/tmp/Convert.vi"
	} else {
		foreignPath = `C:\work\Convert.vi`
	}

	_, err := flattenVIPath(foreignPath)
	if err == nil {
		t.Fatalf("flattenVIPath(%q) error = nil, want error", foreignPath)
	}
	if !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("flattenVIPath(%q) error = %q, want not-supported message", foreignPath, err)
	}
}

func TestFlattenUnixPathUsesPTH2Absolute(t *testing.T) {
	flat, err := flattenUnixPath("/Users/peter/project/Convert.vi")
	if err != nil {
		t.Fatalf("flattenUnixPath() error = %v", err)
	}

	if got := string(flat[:4]); got != flatPathCodePTH2 {
		t.Fatalf("magic = %q, want %q", got, flatPathCodePTH2)
	}

	payloadLen := int(binary.BigEndian.Uint32(flat[4:8]))
	if payloadLen != len(flat)-8 {
		t.Fatalf("payload len = %d, actual = %d", payloadLen, len(flat)-8)
	}

	if got := string(flat[8:12]); got != flatPathAbsSub {
		t.Fatalf("subcode = %q, want %q", got, flatPathAbsSub)
	}
}

func TestFlattenWindowsPathUsesPTH0Absolute(t *testing.T) {
	flat, err := flattenWindowsPath(`C:\work\Convert.vi`)
	if err != nil {
		t.Fatalf("flattenWindowsPath() error = %v", err)
	}

	if got := string(flat[:4]); got != flatPathCodePTH0 {
		t.Fatalf("magic = %q, want %q", got, flatPathCodePTH0)
	}

	payloadLen := int(binary.BigEndian.Uint32(flat[4:8]))
	if payloadLen != len(flat)-8 {
		t.Fatalf("payload len = %d, actual = %d", payloadLen, len(flat)-8)
	}

	if got := int16(binary.BigEndian.Uint16(flat[8:10])); got != oldPathTypeAbs {
		t.Fatalf("path type = %d, want %d", got, oldPathTypeAbs)
	}
}

func TestUnflattenPathRestoresWindowsAbsolutePath(t *testing.T) {
	flat, err := flattenWindowsPath(`C:\work\Convert.vi`)
	if err != nil {
		t.Fatalf("flattenWindowsPath() error = %v", err)
	}

	value, consumed, err := unflattenPath(flat)
	if err != nil {
		t.Fatalf("unflattenPath() error = %v", err)
	}
	if consumed != len(flat) {
		t.Fatalf("consumed = %d, want %d", consumed, len(flat))
	}
	// On Windows, PTH0 abs paths unflatten to drive-letter paths.
	// On macOS/Linux, they unflatten to Unix paths (first part becomes a directory).
	var want string
	if runtime.GOOS == "windows" {
		want = `C:\work\Convert.vi`
	} else {
		want = "/C/work/Convert.vi"
	}
	if got, ok := value.(string); !ok || got != want {
		t.Fatalf("value = %#v, want %q", value, want)
	}
}

func TestUnflattenPathRestoresWindowsUNCPath(t *testing.T) {
	flat, err := flattenWindowsPath(`\\server\share\Convert.vi`)
	if err != nil {
		t.Fatalf("flattenWindowsPath() error = %v", err)
	}

	value, _, err := unflattenPath(flat)
	if err != nil {
		t.Fatalf("unflattenPath() error = %v", err)
	}
	if got, ok := value.(string); !ok || got != `\\server\share\Convert.vi` {
		t.Fatalf("value = %#v, want %q", value, `\\server\share\Convert.vi`)
	}
}
