//go:build linux

package labview

import "path/filepath"

// labviewExecutableFilename is the LabVIEW executable filename on Linux.
const labviewExecutableFilename = "labview"

// labviewExecutableFullPath returns the full path to the LabVIEW executable given the install directory.
// On Linux, the executable is directly in the install directory.
func labviewExecutableFullPath(installPath string) string {
	return filepath.Join(installPath, labviewExecutableFilename)
}
