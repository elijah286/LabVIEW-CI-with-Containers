// Package labview provides utilities for managing LabVIEW processes.
package labview

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/process"
)

// KillProcess terminates a process and waits for it to exit.
// The proc argument must be the original *os.Process returned by cmd.Start()
// so that Wait can properly reap the child. Returns nil if proc is nil.
func KillProcess(proc *os.Process) error {
	if proc == nil {
		return nil
	}

	pid := proc.Pid
	slog.Info("Terminating LabVIEW process", "pid", pid)
	if err := proc.Kill(); err != nil {
		if !isProcessAlive(pid) {
			slog.Info("LabVIEW process already exited", "pid", pid)
			return nil
		}
		return fmt.Errorf("failed to kill process %d: %w", pid, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		_, err := proc.Wait()
		done <- err
	}()

	select {
	case <-done:
		slog.Info("LabVIEW process terminated", "pid", pid)
		return nil
	case <-ctx.Done():
		slog.Error("LabVIEW didn't terminate within timeout", "pid", pid)
		return fmt.Errorf("timeout waiting for process %d to terminate", pid)
	}
}

// IsLabVIEWRunning checks if LabVIEW is currently running.
// If installPath is non-empty, only returns true if the running LabVIEW is from that install directory.
func IsLabVIEWRunning(installPath string) (bool, error) {
	processes, err := process.Processes()
	if err != nil {
		return false, fmt.Errorf("failed to list processes: %w", err)
	}

	for _, p := range processes {
		name, err := p.Name()
		if err != nil {
			continue
		}

		if name == labviewExecutableFilename {
			if installPath == "" {
				return true, nil
			}

			// Check if the process executable is inside the given install path
			exePath, err := p.Exe()
			if err != nil {
				continue
			}

			if strings.Contains(exePath, installPath) {
				return true, nil
			}
		}
	}

	return false, nil
}

// KillLabVIEW terminates all running LabVIEW processes.
// If installPath is non-empty, only kills the LabVIEW process from that install directory.
func KillLabVIEW(installPath string) error {
	processes, err := process.Processes()
	if err != nil {
		return fmt.Errorf("failed to list processes: %w", err)
	}

	for _, p := range processes {
		name, err := p.Name()
		if err != nil {
			continue
		}

		if name == labviewExecutableFilename {
			if installPath != "" {
				exePath, err := p.Exe()
				if err != nil {
					continue
				}
				if !strings.Contains(exePath, installPath) {
					continue
				}
			}

			slog.Info("Terminating LabVIEW process", "pid", p.Pid)
			if err := p.Kill(); err != nil {
				slog.Warn("Failed to kill LabVIEW process", "pid", p.Pid, "error", err)
				// Continue anyway - process may have already exited
			}

			// Wait for process to terminate.
			// Note: Kill() sends SIGKILL which is the most forceful signal and cannot be ignored.
			// If the process doesn't terminate, it's likely in an uninterruptible kernel state.
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)

		waitLoop:
			for {
				running, _ := p.IsRunning()
				if !running {
					break waitLoop
				}
				select {
				case <-ctx.Done():
					cancel()
					slog.Error("LabVIEW didn't terminate within timeout", "pid", p.Pid)
					return fmt.Errorf("timeout waiting for LabVIEW to terminate (pid %d)", p.Pid)
				case <-time.After(1 * time.Second):
				}
			}
			cancel()
		}
	}

	return nil
}

// StartLabVIEWServerConfig holds configuration for starting a LabVIEW server.
type StartLabVIEWServerConfig struct {
	// InstallPath is the LabVIEW install directory (e.g., "/usr/local/natinst/LabVIEW-2026-64").
	// Required; the service will not start LabVIEW if this is empty.
	// Port is the automation listener port.
	Port        int
	InstallPath string
	// ConfigPath is the path to the LabVIEW config file. Empty to skip -pref flag.
	ConfigPath string
	// ListenerVIPath is the path to the listener VI.
	ListenerVIPath string
	// WaitUntilLoaded blocks until the server is ready or ctx is cancelled.
	WaitUntilLoaded bool
}

// StartLabVIEWServer starts LabVIEW with the automation listener.
// Returns the started process so callers can later terminate only the instance they launched.
// If cfg.WaitUntilLoaded is true, blocks until the server is ready or ctx is cancelled.
// The caller should set a deadline on ctx if a timeout is desired.
func StartLabVIEWServer(ctx context.Context, cfg StartLabVIEWServerConfig) (*os.Process, error) {
	if cfg.InstallPath == "" {
		return nil, fmt.Errorf("InstallPath is required to start LabVIEW")
	}

	labVIEWExe := labviewExecutableFullPath(cfg.InstallPath)

	// Verify the executable exists
	if _, err := os.Stat(labVIEWExe); os.IsNotExist(err) {
		return nil, fmt.Errorf("LabVIEW executable not found: %s", labVIEWExe)
	}

	if cfg.ListenerVIPath == "" {
		return nil, fmt.Errorf("listener VI path is required")
	}

	if _, err := os.Stat(cfg.ListenerVIPath); err != nil {
		if os.IsNotExist(err) {
			if runtime.GOOS == "windows" {
				return nil, fmt.Errorf("listener VI not found: %s (run scripts/Setup-Windows.ps1 as Administrator to install Nigel VIs and LabVIEW.ini)", cfg.ListenerVIPath)
			}
			return nil, fmt.Errorf("listener VI not found: %s", cfg.ListenerVIPath)
		}
		return nil, fmt.Errorf("failed to access listener VI path %s: %w", cfg.ListenerVIPath, err)
	}

	// Build command arguments.
	// -pref points to our checked-in config that suppresses dialogs for headless operation,
	// avoiding the need for a writable ~/natinst directory.
	var args []string
	if cfg.ConfigPath != "" {
		args = append(args, "-pref", cfg.ConfigPath)
	}
	args = append(args, cfg.ListenerVIPath, "--", "--port", fmt.Sprintf("%d", cfg.Port))

	slog.Info("Starting LabVIEW", "executable", labVIEWExe, "vi", cfg.ListenerVIPath, "port", cfg.Port)

	// Start the process.
	// Note: We intentionally use exec.Command instead of exec.CommandContext because
	// the context is only for controlling startup timeout, not the process lifetime.
	// LabVIEW should continue running after startup completes.
	cmd := exec.Command(labVIEWExe, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	slog.Info("NOTE: libniDotNETCoreInterop.so warnings on Linux are expected until Bug AB#3728759 is fixed!")

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start LabVIEW: %w", err)
	}

	pid := cmd.Process.Pid
	slog.Info("LabVIEW process started", "pid", pid)

	if cfg.WaitUntilLoaded {
		if err := WaitUntilServerLoaded(ctx, "localhost", cfg.Port); err != nil {
			if isProcessAlive(pid) {
				slog.Error("LabVIEW process still alive but listener not ready", "pid", pid)
			} else {
				slog.Error("LabVIEW process no longer exists after timeout", "pid", pid)
			}

			// Check if anything is listening on the expected port
			slog.Error("LabVIEW port check", "port", cfg.Port, "reachable", IsServerReady("localhost", cfg.Port, 1*time.Second))

			return cmd.Process, fmt.Errorf("LabVIEW server did not become ready: %w", err)
		}
	}

	return cmd.Process, nil
}

// WaitUntilServerLoaded waits until the LabVIEW server is ready to accept connections.
// The caller must set a deadline on ctx to control the timeout.
func WaitUntilServerLoaded(ctx context.Context, host string, port int) error {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	// Try immediately before waiting
	if err := Ping(host, port, 2*time.Second); err == nil {
		slog.Info("LabVIEW server is ready", "host", host, "port", port)
		return nil
	}

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for LabVIEW server at %s:%d: %w", host, port, ctx.Err())
		case <-ticker.C:
			if err := Ping(host, port, 2*time.Second); err == nil {
				slog.Info("LabVIEW server is ready", "host", host, "port", port)
				return nil
			}
		}
	}
}

// IsServerReady checks if the LabVIEW server is ready to accept connections.
func IsServerReady(host string, port int, timeout time.Duration) bool {
	return Ping(host, port, timeout) == nil
}
