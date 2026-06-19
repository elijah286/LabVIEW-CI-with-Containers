//go:build windows

package labview

import "path/filepath"

// labviewExecutableFilename is the LabVIEW executable filename on Windows.
const labviewExecutableFilename = "LabVIEW.exe"

// labviewExecutableFullPath returns the full path to the LabVIEW executable given the install directory.
// On Windows, the executable is directly in the install directory.
func labviewExecutableFullPath(installPath string) string {
	return filepath.Join(installPath, labviewExecutableFilename)
}
