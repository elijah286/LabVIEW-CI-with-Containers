package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFromXMLCmd_Run_FileNotFound(t *testing.T) {
	cmd := &FromXMLCmd{
		Path:    "/nonexistent/file.xml",
		Output:  "output.vi",
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

func TestFromXMLCmd_Run_InputIsDirectory(t *testing.T) {
	dir := t.TempDir()
	xmlDir := filepath.Join(dir, "subdir.xml")
	if err := os.Mkdir(xmlDir, 0755); err != nil {
		t.Fatal(err)
	}

	cmd := &FromXMLCmd{
		Path:    xmlDir,
		Output:  "output.vi",
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

func TestFromXMLCmd_Run_WrongExtension(t *testing.T) {
	dir := t.TempDir()
	viFile := filepath.Join(dir, "file.vi")
	if err := os.WriteFile(viFile, []byte("binary"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &FromXMLCmd{
		Path:    viFile,
		Output:  "output.vi",
		Timeout: 5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for wrong extension")
	}
	if got := err.Error(); !contains(got, "expected a .xml file") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestFromXMLCmd_Run_MissingOutput(t *testing.T) {
	dir := t.TempDir()
	xmlFile := filepath.Join(dir, "test.xml")
	if err := os.WriteFile(xmlFile, []byte("<xml/>"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &FromXMLCmd{
		Path:    xmlFile,
		Output:  "", // missing
		Timeout: 5 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err == nil {
		t.Fatal("expected error for missing output")
	}
	if got := err.Error(); !contains(got, "output path is required") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestFromXMLCmd_Run_FileTooLarge(t *testing.T) {
	dir := t.TempDir()
	xmlFile := filepath.Join(dir, "big.xml")
	data := make([]byte, 2*1024*1024)
	if err := os.WriteFile(xmlFile, data, 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &FromXMLCmd{
		Path:        xmlFile,
		Output:      filepath.Join(dir, "output.vi"),
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

func TestFromXMLCmd_Run_ConnectionRefused(t *testing.T) {
	dir := t.TempDir()
	xmlFile := filepath.Join(dir, "test.xml")
	if err := os.WriteFile(xmlFile, []byte("<xml/>"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &FromXMLCmd{
		Path:        xmlFile,
		Output:      filepath.Join(dir, "output.vi"),
		MaxFileSize: 10,
		Timeout:     1 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	// With COM, the command may succeed if LabVIEW is running, or fail
	// with a COM error if not. Either way, it should get past validation.
	if err != nil {
		got := err.Error()
		if contains(got, "cannot access file") || contains(got, "expected a .xml file") {
			t.Fatalf("failed during validation: %s", got)
		}
	}
}
