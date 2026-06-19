package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestToImagesCmd_Run_FileNotFound(t *testing.T) {
	cmd := &ToImagesCmd{
		Path:    []string{"/nonexistent/file.vi"},
		Timeout: 5 * time.Second,
	}

	err := cmd.Run(&Globals{})
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
	if got := err.Error(); !strings.Contains(got, "cannot access file") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToImagesCmd_Run_InputIsDirectory(t *testing.T) {
	dir := t.TempDir()
	viDir := filepath.Join(dir, "subdir.vi")
	if err := os.Mkdir(viDir, 0755); err != nil {
		t.Fatal(err)
	}

	cmd := &ToImagesCmd{
		Path:    []string{viDir},
		Timeout: 5 * time.Second,
	}

	err := cmd.Run(&Globals{})
	if err == nil {
		t.Fatal("expected error for directory input")
	}
	if got := err.Error(); !strings.Contains(got, "input path is a directory") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToImagesCmd_Run_WrongExtension(t *testing.T) {
	dir := t.TempDir()
	txtFile := filepath.Join(dir, "file.txt")
	if err := os.WriteFile(txtFile, []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &ToImagesCmd{
		Path:    []string{txtFile},
		Timeout: 5 * time.Second,
	}

	err := cmd.Run(&Globals{})
	if err == nil {
		t.Fatal("expected error for wrong extension")
	}
	if got := err.Error(); !strings.Contains(got, "expected a .vi file") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestToImagesCmd_Run_FileTooLarge(t *testing.T) {
	dir := t.TempDir()
	viFile := filepath.Join(dir, "big.vi")
	data := make([]byte, 2*1024*1024)
	if err := os.WriteFile(viFile, data, 0644); err != nil {
		t.Fatal(err)
	}

	cmd := &ToImagesCmd{
		Path:        []string{viFile},
		MaxFileSize: 1,
		Timeout:     5 * time.Second,
	}

	err := cmd.Run(&Globals{})
	if err == nil {
		t.Fatal("expected error for oversized file")
	}
	if got := err.Error(); !strings.Contains(got, "exceeds maximum") {
		t.Errorf("unexpected error: %s", got)
	}
}

func TestDefaultGetVIInfoVIPath_Embedded(t *testing.T) {
	// With no explicit entry VI path, defaultGetVIInfoVIPath should use the
	// embedded toimages directory tree and extract successfully.
	t.Setenv("LVCTL_CACHE_DIR", t.TempDir())

	path, err := defaultGetVIInfoVIPath()
	if err != nil {
		t.Fatalf("defaultGetVIInfoVIPath with embedded assets failed: %v", err)
	}
	if _, statErr := os.Stat(path); statErr != nil {
		t.Fatalf("toimages entry VI not found at %q: %v", path, statErr)
	}

	if base := filepath.Base(path); base != "Get VI Info.vi" {
		t.Fatalf("unexpected toimages entry VI %q", path)
	}
}

func TestDefaultGetVIInfoVIPath_ReusesCachedExtraction(t *testing.T) {
	t.Setenv("LVCTL_CACHE_DIR", t.TempDir())

	firstPath, err := defaultGetVIInfoVIPath()
	if err != nil {
		t.Fatalf("first resolve failed: %v", err)
	}
	secondPath, err := defaultGetVIInfoVIPath()
	if err != nil {
		t.Fatalf("second resolve failed: %v", err)
	}
	if firstPath != secondPath {
		t.Fatalf("expected cached path reuse, got %q then %q", firstPath, secondPath)
	}
}

func TestCachedToImagesDir_UsesOverrideCacheRoot(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("LVCTL_CACHE_DIR", cacheRoot)

	cacheDir, err := cachedToImagesDir("cache-key")
	if err != nil {
		return
	}
	if !strings.Contains(cacheDir, filepath.Join(cacheRoot, "lvctl", "toimages")) {
		t.Fatalf("cachedToImagesDir() = %q, want path under %q", cacheDir, cacheRoot)
	}
}

func TestAcquireToImagesLock_SerializesCallers(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("LVCTL_CACHE_DIR", cacheRoot)

	first, err := acquireToImagesLock(time.Second)
	if err != nil {
		t.Fatalf("first acquire failed: %v", err)
	}
	defer first.Close()

	started := make(chan struct{})
	released := make(chan struct{})
	acquired := make(chan struct{})
	errCh := make(chan error, 1)

	go func() {
		close(started)
		lock, err := acquireToImagesLock(2 * time.Second)
		if err != nil {
			errCh <- err
			return
		}
		lock.Close()
		close(acquired)
	}()

	<-started
	select {
	case <-acquired:
		t.Fatal("second acquire succeeded before first lock released")
	case err := <-errCh:
		t.Fatalf("second acquire failed early: %v", err)
	case <-time.After(300 * time.Millisecond):
	}

	var once sync.Once
	release := func() {
		once.Do(func() {
			first.Close()
			close(released)
		})
	}
	defer release()
	release()

	select {
	case <-acquired:
	case err := <-errCh:
		t.Fatalf("second acquire failed: %v", err)
	case <-time.After(2 * time.Second):
		<-released
		t.Fatal("timed out waiting for second acquire")
	}
}

func TestAcquireToImagesLock_RemovesStaleLock(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("LVCTL_CACHE_DIR", cacheRoot)

	lockPath, err := toImagesLockPath()
	if err != nil {
		t.Fatalf("toImagesLockPath failed: %v", err)
	}
	if err := os.MkdirAll(lockPath, 0o700); err != nil {
		t.Fatalf("mkdir stale lock failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(lockPath, toImagesLockPIDFile), []byte("999999"), 0o600); err != nil {
		t.Fatalf("write stale pid failed: %v", err)
	}

	lock, err := acquireToImagesLock(time.Second)
	if err != nil {
		t.Fatalf("acquire after stale lock failed: %v", err)
	}
	defer lock.Close()

	pidBytes, err := os.ReadFile(filepath.Join(lockPath, toImagesLockPIDFile))
	if err != nil {
		t.Fatalf("read refreshed pid failed: %v", err)
	}
	if strings.TrimSpace(string(pidBytes)) != "" && strings.TrimSpace(string(pidBytes)) == "999999" {
		t.Fatal("stale lock pid was not replaced")
	}
}
