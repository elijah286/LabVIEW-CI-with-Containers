//go:build windows

package labview

import (
	"errors"
	"syscall"
)

// isProcessAlive checks whether a process with the given PID is still running.
// On Windows, STILL_ACTIVE (259) means the process is still alive.
func isProcessAlive(pid int) bool {
	const processQueryLimitedInformation = 0x1000
	const stillActive = 259

	handle, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		if errors.Is(err, syscall.ERROR_ACCESS_DENIED) {
			return true
		}
		return false
	}
	defer syscall.CloseHandle(handle)

	var exitCode uint32
	if err := syscall.GetExitCodeProcess(handle, &exitCode); err != nil {
		return false
	}

	return exitCode == stillActive
}
