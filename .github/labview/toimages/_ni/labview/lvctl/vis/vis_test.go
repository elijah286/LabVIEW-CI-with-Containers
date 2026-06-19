package vis

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestExtractZip_RejectsZipSlip(t *testing.T) {
	dir := t.TempDir()
	data := makeZipFixture(t, map[string]string{
		"../escape.txt": "nope",
	})

	err := ExtractZipData(data, dir)
	if err == nil {
		t.Fatal("expected zip slip extraction to fail")
	}
}

func TestExtractZip_RejectsAbsolutePath(t *testing.T) {
	dir := t.TempDir()
	data := makeZipFixture(t, map[string]string{
		"/absolute.txt": "nope",
	})

	err := ExtractZipData(data, dir)
	if err == nil {
		t.Fatal("expected absolute-path extraction to fail")
	}
}

func TestExtractZip_CreatesPrivateDirectories(t *testing.T) {
	dir := t.TempDir()
	data := makeZipFixture(t, map[string]string{
		"nested/file.txt": "ok",
	})

	if err := ExtractZipData(data, dir); err != nil {
		t.Fatalf("ExtractZipData() error = %v", err)
	}

	info, err := os.Stat(filepath.Join(dir, "nested"))
	if err != nil {
		t.Fatalf("stat nested dir: %v", err)
	}
	// Windows does not enforce POSIX permission bits; os.Stat always
	// reports 0o777 for directories regardless of what MkdirAll requested,
	// so we can only verify the 0o700 intent on Unix.
	if runtime.GOOS != "windows" {
		if got := info.Mode().Perm(); got != 0o700 {
			t.Fatalf("nested dir perms = %o, want 700", got)
		}
	}
}

func TestEmbeddedToImagesZipDoesNotContainSymlinks(t *testing.T) {
	archive, err := zip.NewReader(bytes.NewReader(ToImagesZip), int64(len(ToImagesZip)))
	if err != nil {
		t.Fatalf("open embedded toimages zip: %v", err)
	}

	for _, file := range archive.File {
		if file.Mode()&os.ModeSymlink != 0 {
			t.Fatalf("embedded toimages zip contains symlink entry %q", file.Name)
		}
	}
}

func makeZipFixture(t *testing.T, files map[string]string) []byte {
	t.Helper()

	var buf bytes.Buffer
	archive := zip.NewWriter(&buf)
	for name, content := range files {
		writer, err := archive.Create(name)
		if err != nil {
			t.Fatalf("create zip entry %s: %v", name, err)
		}
		if _, err := writer.Write([]byte(content)); err != nil {
			t.Fatalf("write zip entry %s: %v", name, err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatalf("close zip archive: %v", err)
	}

	return buf.Bytes()
}
