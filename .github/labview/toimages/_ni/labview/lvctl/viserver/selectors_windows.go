//go:build windows

package viserver

// Windows build-compat shim.
//
// vi_method_metadata.go is untagged (compiled on every platform) and references
// these VI Server method selectors, but their definitions live in
// viserver_other.go, which is //go:build !windows and therefore excluded from the
// Windows build. Without these, the package does not compile for GOOS=windows.
//
// These are platform-independent "well-known method selectors from objsels.h"
// (stable LabVIEW internals), so defining them here for Windows matches the
// non-Windows values exactly. Proper upstream fix: move the objsels.h selector
// constants out of viserver_other.go into an untagged file.
const (
	viRunMethod      int32 = 1003
	viAbortMethod    int32 = 1004
	viSetCtrlVariant int32 = 1051
	viGetCtrlVariant int32 = 1052
)
