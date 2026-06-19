package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestToXMLCmd_Run_FileNotFound(t *testing.T) {
	cmd := &ToXMLCmd{
		Path:    "/nonexistent/file.vi",
		Timeout: 5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
	if got := err.Error(); !contains(got, "cannot access file") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToXMLCmd_Run_InputIsDirectory(t *testing.T) {
	dir := t.TempDir()
	viDir := filepath.Join(dir, "subdir.vi")
	if err := os.Mkdir(viDir, 0755); err != nil {
		t.Fatal(err)
	}

	cmd := &ToXMLCmd{
		Path:    viDir,
		Timeout: 5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for directory input")
	}
	if got := err.Error(); !contains(got, "input path is a directory") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToXMLCmd_Run_WrongExtension(t *testing.T) {
	dir := t.TempDir()
	txtFile := filepath.Join(dir, "file.txt")
	if err := os.WriteFile(txtFile, []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &ToXMLCmd{
		Path:    txtFile,
		Timeout: 5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for wrong extension")
	}
	if got := err.Error(); !contains(got, "expected a .vi file") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToXMLCmd_Run_FileTooLarge(t *testing.T) {
	dir := t.TempDir()
	viFile := filepath.Join(dir, "big.vi")
	// Create a file that exceeds 1 MiB limit
	data := make([]byte, 2*1024*1024)
	if err := os.WriteFile(viFile, data, 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &ToXMLCmd{
		Path:        viFile,
		MaxFileSize: 1, // 1 MiB
		Timeout:     5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for oversized file")
	}
	if got := err.Error(); !contains(got, "exceeds maximum") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToXMLCmd_Run_ConnectionRefused(t *testing.T) {
	dir := t.TempDir()
	viFile := filepath.Join(dir, "test.vi")
	if err := os.WriteFile(viFile, []byte("fake-vi-content"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &ToXMLCmd{
		Path:        viFile,
		MaxFileSize: 10,
		Timeout:     1 * time.Second,
	}
	// COM connects directly to LabVIEW, so the host/port are unused.
	// This test now verifies the command runs through validation.
	globals := &Globals{}

	err := cmd.Run(globals)
	// With COM, the command may succeed if LabVIEW is running, or fail
	// with a COM error if not. Either way, it should get past validation.
	if err != nil {
		got := err.Error()
		if contains(got, "cannot access file") || contains(got, "expected a .vi file") {
			t.Fatalf("failed during validation: %s", got)
		}
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && containsStr(s, substr)
}

func containsStr(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
