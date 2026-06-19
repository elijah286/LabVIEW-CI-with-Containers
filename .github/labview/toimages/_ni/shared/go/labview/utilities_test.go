package labview

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestLabviewExePath(t *testing.T) {
	installPath := filepath.Join("some", "install", "path")
	result := labviewExecutableFullPath(installPath)
	if result == "" {
		t.Error("labviewExecutableFullPath() returned empty string")
	}
	// The result should contain the install path
	if !strings.Contains(result, installPath) {
		t.Errorf("labviewExecutableFullPath() = %q, want to contain install path", result)
	}
	// The result should contain the executable name
	if !strings.Contains(result, labviewExecutableFilename) {
		t.Errorf("labviewExecutableFullPath() = %q, want to contain %q", result, labviewExecutableFilename)
	}
}

func TestIsLabVIEWRunning(t *testing.T) {
	t.Run("returns false when LabVIEW is not running", func(t *testing.T) {
		// In dev environment, LabVIEW should not be running
		running, err := IsLabVIEWRunning("")
		if err != nil {
			t.Fatalf("IsLabVIEWRunning() error = %v", err)
		}

		// We can't assert it's false because it might be running in CI,
		// but we can at least verify the function doesn't error
		_ = running
	})

	t.Run("returns false for non-existent version", func(t *testing.T) {
		running, err := IsLabVIEWRunning("9999")
		if err != nil {
			t.Fatalf("IsLabVIEWRunning() error = %v", err)
		}

		if running {
			t.Error("expected IsLabVIEWRunning to return false for non-existent version")
		}
	})
}

func TestKillLabVIEW(t *testing.T) {
	t.Run("succeeds when no LabVIEW is running", func(t *testing.T) {
		// This should not error even if LabVIEW is not running
		err := KillLabVIEW("nonexistent-version-9999")
		if err != nil {
			t.Fatalf("KillLabVIEW() error = %v", err)
		}
	})
}

func TestKillProcess(t *testing.T) {
	t.Run("succeeds for nil process", func(t *testing.T) {
		if err := KillProcess(nil); err != nil {
			t.Fatalf("KillProcess(nil) error = %v, want nil", err)
		}
	})

	t.Run("kills a real process", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("sleep command not available on Windows")
		}

		cmd := exec.Command("sleep", "60")
		if err := cmd.Start(); err != nil {
			t.Fatalf("failed to start test process: %v", err)
		}

		if err := KillProcess(cmd.Process); err != nil {
			t.Fatalf("KillProcess() error = %v", err)
		}

		if err := cmd.Wait(); err == nil {
			t.Error("expected process to have been killed")
		}
	})
}

func TestIsServerReady(t *testing.T) {
	t.Run("returns false for non-listening port", func(t *testing.T) {
		// Port 59999 should not have anything listening
		ready := IsServerReady("localhost", 59999, 100*time.Millisecond)
		if ready {
			t.Error("expected IsServerReady to return false for non-listening port")
		}
	})
}

func TestPlatformConstants(t *testing.T) {
	// Verify platform constants are non-empty
	if labviewExecutableFilename == "" {
		t.Error("labviewExecutableFilename is empty")
	}
}
