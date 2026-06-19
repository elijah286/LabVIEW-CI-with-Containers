//go:build darwin

package labview

import "path/filepath"

// labviewExecutableFilename is the LabVIEW executable filename on macOS.
// On macOS, the actual binary is inside the .app bundle at:
//
//	LabVIEW.app/Contents/MacOS/LabVIEW
const labviewExecutableFilename = "LabVIEW"

// labviewExecutableFullPath returns the full path to the LabVIEW executable given the install directory.
// On macOS, LabVIEW is distributed as an .app bundle, so the executable is at:
//
//	<install>/LabVIEW.app/Contents/MacOS/LabVIEW
func labviewExecutableFullPath(installPath string) string {
	return filepath.Join(installPath, "LabVIEW.app", "Contents", "MacOS", labviewExecutableFilename)
}
