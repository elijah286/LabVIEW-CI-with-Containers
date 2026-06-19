//go:build linux || darwin

package labview

import "syscall"

// isProcessAlive checks whether a process with the given PID is still running.
// On Unix, signal 0 tests for existence without delivering a signal.
func isProcessAlive(pid int) bool {
	err := syscall.Kill(pid, syscall.Signal(0))
	return err == nil || err == syscall.EPERM
}
