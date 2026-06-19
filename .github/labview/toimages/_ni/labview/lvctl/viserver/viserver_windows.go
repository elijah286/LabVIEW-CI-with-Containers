//go:build windows

package viserver

import (
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/go-ole/go-ole"
	"github.com/go-ole/go-ole/oleutil"
	"golang.org/x/sys/windows/registry"
)

var user32ShowWindow = syscall.NewLazyDLL("user32.dll").NewProc("ShowWindow")

const (
	connectLaunchRetries = 20
	connectRetryDelay    = 1 * time.Second
	connectReadyTimeout  = 20 * time.Second
	connectReadyPoll     = 500 * time.Millisecond
)

// Declared as var (not const) to allow test overrides of poll timing.
var (
	directLaunchPollTimeout = 60 * time.Second
	directLaunchPollDelay   = 2 * time.Second
)

// Package-level function variables for dependency injection in tests.
// These are NOT goroutine-safe; tests that override them must not run in
// parallel (do not use t.Parallel() on tests that mutate these).
var (
	getActiveObjectFn        = oleutil.GetActiveObject
	createObjectFn           = oleutil.CreateObject
	isLabVIEWRunningFn       = isLabVIEWRunning
	getPropertyFn            = oleutil.GetProperty
	putPropertyFn            = oleutil.PutProperty
	sleepFn                  = time.Sleep
	findLabVIEWExeFn         = findLabVIEWExe
	launchLabVIEWProcessFn   = launchLabVIEWProcess
	attachUnknownToSessionFn = attachUnknownToSession
)

type Session struct {
	app          *ole.IDispatch
	launched     bool // true if we started LabVIEW (vs attaching to existing)
	lockedThread bool
}

// Connect attaches to a running LabVIEW instance or launches one via COM.
// If LabVIEW was not already running, Close() will minimize its window.
func Connect() (*Session, error) {
	runtime.LockOSThread()
	if err := ole.CoInitializeEx(0, ole.COINIT_MULTITHREADED); err != nil {
		if oleErr, ok := err.(*ole.OleError); !ok || oleErr.Code() != 0x1 {
			runtime.UnlockOSThread()
			return nil, fmt.Errorf("COM init failed: %w", err)
		}
	}
	session := &Session{lockedThread: true}
	return connectWithSession(session)
}

func connectWithSession(session *Session) (*Session, error) {

	// Record whether LabVIEW was already running so Close() knows whether
	// to minimize the window. This is purely cosmetic — it does NOT gate
	// retry or fallback logic, because the process-list check can report
	// stale/zombie processes and COM activation may still fail even when
	// LabVIEW appears to be running.
	alreadyRunning := isLabVIEWRunningFn()

	// Try GetActiveObject first (cheapest if available in the ROT).
	unknown, err := getActiveObjectFn("LabVIEW.Application")
	if err == nil {
		slog.Debug("Attached to existing LabVIEW instance")
		return attachUnknownToSessionFn(session, unknown, false)
	}

	slog.Info("LabVIEW COM attach failed, attempting CreateObject", "already_running", alreadyRunning)

	// Try CreateObject — on class factory errors, retry a few times since
	// LabVIEW may be slow to register its COM server after startup.
	var lastErr error
	for attempt := 1; attempt <= connectLaunchRetries; attempt++ {
		if attempt > 1 {
			unknown, activeErr := getActiveObjectFn("LabVIEW.Application")
			if activeErr == nil {
				slog.Info("Attached to LabVIEW after launch retry", "attempt", attempt)
				return attachUnknownToSessionFn(session, unknown, !alreadyRunning)
			}
		}

		unknown2, createErr := createObjectFn("LabVIEW.Application")
		if createErr == nil {
			return attachUnknownToSessionFn(session, unknown2, !alreadyRunning)
		}

		lastErr = createErr
		if !shouldRetryLaunch(createErr, attempt) {
			break
		}

		slog.Warn(
			"LabVIEW COM launch failed, retrying",
			"attempt",
			attempt,
			"max_attempts",
			connectLaunchRetries,
			"retry_delay_ms",
			connectRetryDelay.Milliseconds(),
			"error",
			createErr,
		)
		sleepFn(connectRetryDelay)
	}

	// Fallback: if COM CreateObject failed with a class factory error,
	// try launching LabVIEW.exe directly as a process, then attach via
	// GetActiveObject. This works around restricted COM activation in
	// service contexts (e.g. nisvcctl/Discovery). If LabVIEW is already
	// running, we skip the launch but still poll GetActiveObject.
	if lastErr != nil && isClassFactoryError(lastErr) {
		if s, err := directLaunchFallback(session); err == nil {
			return s, nil
		} else {
			slog.Warn("Direct LabVIEW launch fallback also failed", "error", err)
		}
	}

	session.releaseThread()
	if lastErr != nil {
		return nil, fmt.Errorf("failed to launch LabVIEW (is it installed?): %w", lastErr)
	}
	return nil, fmt.Errorf("failed to launch LabVIEW (is it installed?)")
}

func attachUnknownToSession(session *Session, unknown *ole.IUnknown, launched bool) (*Session, error) {
	if unknown == nil {
		session.releaseThread()
		return nil, fmt.Errorf("failed to attach to LabVIEW COM object: received nil IUnknown")
	}

	app, err := unknown.QueryInterface(ole.IID_IDispatch)
	unknown.Release()
	if err != nil {
		session.releaseThread()
		return nil, fmt.Errorf("failed to get LabVIEW IDispatch: %w", err)
	}

	session.app = app
	session.launched = launched
	if err := waitForAppReady(session.app, connectReadyTimeout); err != nil {
		session.Close()
		return nil, err
	}

	return session, nil
}

func waitForAppReady(app *ole.IDispatch, timeout time.Duration) error {
	if timeout <= 0 {
		timeout = connectReadyTimeout
	}

	start := time.Now()
	for {
		if err := probeAppReady(app); err == nil {
			if elapsed := time.Since(start); elapsed >= connectReadyPoll {
				slog.Info("LabVIEW automation ready", "elapsed_ms", elapsed.Milliseconds())
			}
			return nil
		} else if time.Since(start) >= timeout {
			return fmt.Errorf("LabVIEW launched but did not become automation-ready within %v: %w", timeout, err)
		}

		sleepFn(connectReadyPoll)
	}
}

func probeAppReady(app *ole.IDispatch) error {
	_, err := getPropertyFn(app, "Version")
	if err != nil {
		return err
	}
	return nil
}

func shouldRetryLaunch(err error, attempt int) bool {
	if attempt >= connectLaunchRetries || err == nil {
		return false
	}
	return isClassFactoryError(err)
}

// isClassFactoryError returns true if the error indicates COM could not
// activate the LabVIEW class factory (HRESULT 0x80040111 or matching text).
func isClassFactoryError(err error) bool {
	if oleErr := new(ole.OleError); errors.As(err, &oleErr) {
		if oleErr.Code() == 0x80040111 {
			return true
		}
	}

	message := strings.ToLower(err.Error())
	return strings.Contains(message, "classfactory") ||
		strings.Contains(message, "class factory") ||
		strings.Contains(message, "cannot supply requested class")
}

// directLaunchFallback starts LabVIEW.exe directly as a process (if not
// already running), then polls GetActiveObject until it registers in the
// COM Running Object Table. This bypasses COM activation which may be
// restricted in service contexts.
func directLaunchFallback(session *Session) (*Session, error) {
	launchedProcess := false
	if isLabVIEWRunningFn() {
		slog.Info("LabVIEW process exists but COM failed; polling GetActiveObject")
	} else {
		exePath, err := findLabVIEWExeFn()
		if err != nil {
			return nil, fmt.Errorf("cannot find LabVIEW.exe for direct launch: %w", err)
		}

		slog.Info("Falling back to direct LabVIEW.exe launch", "path", exePath)
		if err := launchLabVIEWProcessFn(exePath); err != nil {
			return nil, err
		}
		launchedProcess = true
	}

	// Poll GetActiveObject until LabVIEW registers in the ROT.
	start := time.Now()
	var lastActiveErr error
	for time.Since(start) < directLaunchPollTimeout {
		sleepFn(directLaunchPollDelay)
		unknown, activeErr := getActiveObjectFn("LabVIEW.Application")
		if activeErr == nil {
			slog.Info("Attached to LabVIEW after fallback", "elapsed_ms", time.Since(start).Milliseconds(), "launched_process", launchedProcess)
			return attachUnknownToSessionFn(session, unknown, launchedProcess)
		}
		lastActiveErr = activeErr
		slog.Debug("Waiting for LabVIEW to register in ROT", "elapsed_ms", time.Since(start).Milliseconds(), "error", activeErr)
	}

	return nil, fmt.Errorf("LabVIEW.exe started but did not register for COM within %v: %w", directLaunchPollTimeout, lastActiveErr)
}

// findLabVIEWExe resolves the LabVIEW.exe path from the COM server
// registration in the Windows registry:
//
//	HKCR\LabVIEW.Application\CLSID -> {clsid}
//	HKCR\CLSID\{clsid}\LocalServer32 -> exe path
func findLabVIEWExe() (string, error) {
	progKey, err := registry.OpenKey(registry.CLASSES_ROOT, `LabVIEW.Application\CLSID`, registry.READ)
	if err != nil {
		return "", fmt.Errorf("cannot read LabVIEW.Application CLSID from registry: %w", err)
	}
	defer progKey.Close()

	clsid, _, err := progKey.GetStringValue("")
	if err != nil {
		return "", fmt.Errorf("cannot read CLSID value: %w", err)
	}

	serverKey, err := registry.OpenKey(registry.CLASSES_ROOT, `CLSID\`+clsid+`\LocalServer32`, registry.READ)
	if err != nil {
		return "", fmt.Errorf("cannot read LocalServer32 for %s: %w", clsid, err)
	}
	defer serverKey.Close()

	serverPath, _, err := serverKey.GetStringValue("")
	if err != nil {
		return "", fmt.Errorf("cannot read LocalServer32 value: %w", err)
	}

	// The path may be quoted and/or have flags like /Automation:
	// "C:\Program Files\NI\LabVIEW\LabVIEW.exe" /Automation
	return parseExePath(serverPath), nil
}

// parseExePath extracts the executable path from a LocalServer32 value,
// stripping quotes and trailing flags (e.g. /Automation).
func parseExePath(raw string) string {
	s := strings.TrimSpace(raw)
	if strings.HasPrefix(s, `"`) {
		if end := strings.Index(s[1:], `"`); end >= 0 {
			return s[1 : end+1]
		}
		return strings.Trim(s, `"`)
	}
	// Unquoted: split at first flag-like argument.
	if idx := strings.Index(s, " /"); idx >= 0 {
		return s[:idx]
	}
	if idx := strings.Index(s, " -"); idx >= 0 {
		return s[:idx]
	}
	return s
}

// launchLabVIEWProcess starts LabVIEW.exe directly as a detached process.
// This is a fallback for when COM CreateObject cannot cold-launch LabVIEW
// (e.g. from a service context with restricted COM activation).
func launchLabVIEWProcess(exePath string) error {
	cmd := exec.Command(exePath)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start LabVIEW process at %s: %w", exePath, err)
	}
	// Release the handle so LabVIEW outlives this process.
	cmd.Process.Release()
	return nil
}

// Close releases the COM connection. If we launched LabVIEW, minimize
// its main window so it stays available but out of the way.
func (s *Session) Close() {
	defer s.releaseThread()

	if s.app != nil {
		if s.launched {
			if err := s.ensureAutomaticCloseDisabled(); err != nil {
				slog.Warn("Failed to disable AutomaticClose on auto-launched LabVIEW", "error", err)
			}
			slog.Debug("Minimizing LabVIEW main window")
			minimizeLabVIEW()
		}
		s.app.Release()
		s.app = nil
	}
}

func (s *Session) ensureAutomaticCloseDisabled() error {
	if s == nil || s.app == nil {
		return nil
	}
	if _, err := putPropertyFn(s.app, "AutomaticClose", false); err != nil {
		return fmt.Errorf("set application property %q: %w", "AutomaticClose", err)
	}
	return nil
}

func (s *Session) releaseThread() {
	if !s.lockedThread {
		return
	}
	ole.CoUninitialize()
	runtime.UnlockOSThread()
	s.lockedThread = false
}

// minimizeLabVIEW finds the LabVIEW window by title prefix and minimizes it.
func minimizeLabVIEW() {
	user32 := syscall.NewLazyDLL("user32.dll")
	enumWindows := user32.NewProc("EnumWindows")
	getWindowTextW := user32.NewProc("GetWindowTextW")
	isWindowVisible := user32.NewProc("IsWindowVisible")

	const swMinimize = 6 // SW_MINIMIZE

	// EnumWindows callback: find visible windows whose title starts with "LabVIEW".
	cb := syscall.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
		vis, _, _ := isWindowVisible.Call(hwnd)
		if vis == 0 {
			return 1 // continue
		}
		buf := make([]uint16, 256)
		getWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		title := syscall.UTF16ToString(buf)
		if len(title) >= 7 && title[:7] == "LabVIEW" {
			slog.Debug("Minimizing LabVIEW window", "hwnd", hwnd, "title", title)
			user32ShowWindow.Call(hwnd, uintptr(swMinimize))
		}
		return 1 // continue enumeration
	})

	enumWindows.Call(cb, 0)
}

func (s *Session) RunVI(timeout time.Duration, viPath string, controls map[string]any, indicatorNames []string, searchDirs ...string) (map[string]any, error) {
	slog.Debug("RunVI", "viPath", viPath, "controls", len(controls), "indicators", len(indicatorNames))

	for _, dir := range searchDirs {
		if err := s.addSearchPath(dir); err != nil {
			slog.Warn("failed to add search path", "dir", dir, "error", err)
		}
	}

	viRef, err := oleutil.CallMethod(s.app, "GetVIReference", viPath, "", false, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to open VI %s: %w", viPath, err)
	}
	vi := viRef.ToIDispatch()
	defer vi.Release()

	for name, value := range controls {
		slog.Debug("SetControlValue", "name", name, "type", fmt.Sprintf("%T", value))
		if _, err := oleutil.CallMethod(vi, "SetControlValue", name, value); err != nil {
			return nil, fmt.Errorf("failed to set control %q: %w", name, err)
		}
	}

	slog.Debug("Starting VI execution (async)")
	if _, err := oleutil.CallMethod(vi, "Run", false); err != nil {
		return nil, fmt.Errorf("failed to start VI: %w", err)
	}

	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	start := time.Now()
	for {
		execState, err := oleutil.GetProperty(vi, "ExecState")
		if err != nil {
			return nil, fmt.Errorf("failed to read ExecState: %w", err)
		}
		if execState.Val == 1 {
			break
		}
		if time.Since(start) > timeout {
			oleutil.CallMethod(vi, "Abort")
			return nil, fmt.Errorf("VI execution timed out after %v", timeout)
		}
		time.Sleep(50 * time.Millisecond)
	}
	slog.Debug("VI execution complete", "elapsed", time.Since(start))

	result := make(map[string]any, len(indicatorNames))
	for _, name := range indicatorNames {
		val, err := oleutil.CallMethod(vi, "GetControlValue", name)
		if err != nil {
			return nil, fmt.Errorf("failed to read indicator %q: %w", name, err)
		}
		result[name] = val.Value()
	}
	return result, nil
}

func (s *Session) addSearchPath(dir string) error {
	for _, prop := range []string{"VISearchPath", "LibraryPaths", "ViSearchPaths"} {
		pathsVar, err := oleutil.GetProperty(s.app, prop)
		if err != nil {
			continue
		}
		current := pathsVar.ToString()
		if strings.Contains(current, dir) {
			return nil
		}
		newPaths := current
		if newPaths != "" {
			newPaths += ";"
		}
		newPaths += dir
		slog.Debug("Adding to LabVIEW search paths", "property", prop, "dir", dir)
		_, err = putPropertyFn(s.app, prop, newPaths)
		if err != nil {
			return fmt.Errorf("failed to set %s: %w", prop, err)
		}
		return nil
	}
	slog.Debug("Could not find a search path property, relying on VI-relative resolution")
	return nil
}

// GetAppProperty reads a property from the LabVIEW Application object.
func (s *Session) GetAppProperty(name string) (interface{}, error) {
	v, err := oleutil.GetProperty(s.app, name)
	if err != nil {
		return nil, fmt.Errorf("get property %q: %w", name, err)
	}
	return v.Value(), nil
}

// SetAppProperty writes a property on the LabVIEW Application object.
func (s *Session) SetAppProperty(name string, value interface{}) error {
	if _, err := putPropertyFn(s.app, name, value); err != nil {
		return fmt.Errorf("set property %q: %w", name, err)
	}
	return nil
}

// CallAppMethod invokes a method on the LabVIEW Application object.
func (s *Session) CallAppMethod(name string, args ...interface{}) (interface{}, error) {
	v, err := oleutil.CallMethod(s.app, name, args...)
	if err != nil {
		return nil, fmt.Errorf("call method %q: %w", name, err)
	}
	return v.Value(), nil
}

// GetVIProperty reads a property from a VI object.
func (s *Session) GetVIProperty(viPath string, name string) (interface{}, error) {
	viRef, err := oleutil.CallMethod(s.app, "GetVIReference", viPath, "", false, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to open VI %s: %w", viPath, err)
	}
	vi := viRef.ToIDispatch()
	defer vi.Release()

	v, err := oleutil.GetProperty(vi, name)
	if err != nil {
		return nil, fmt.Errorf("get VI property %q: %w", name, err)
	}
	return v.Value(), nil
}

// SetVIProperty writes a property on a VI object.
func (s *Session) SetVIProperty(viPath string, name string, value interface{}) error {
	viRef, err := oleutil.CallMethod(s.app, "GetVIReference", viPath, "", false, 0)
	if err != nil {
		return fmt.Errorf("failed to open VI %s: %w", viPath, err)
	}
	vi := viRef.ToIDispatch()
	defer vi.Release()

	if _, err := putPropertyFn(vi, name, value); err != nil {
		return fmt.Errorf("set VI property %q: %w", name, err)
	}
	return nil
}

// CallVIMethod invokes a method on a VI object.
func (s *Session) CallVIMethod(viPath string, name string, args ...interface{}) (interface{}, error) {
	viRef, err := oleutil.CallMethod(s.app, "GetVIReference", viPath, "", false, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to open VI %s: %w", viPath, err)
	}
	vi := viRef.ToIDispatch()
	defer vi.Release()

	v, err := oleutil.CallMethod(vi, name, args...)
	if err != nil {
		return nil, fmt.Errorf("call VI method %q: %w", name, err)
	}
	return v.Value(), nil
}

// isLabVIEWRunning checks if a LabVIEW process is already running.
func isLabVIEWRunning() bool {
	snapshot, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(snapshot)

	var entry syscall.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := syscall.Process32First(snapshot, &entry); err != nil {
		return false
	}
	for {
		name := strings.ToLower(syscall.UTF16ToString(entry.ExeFile[:]))
		if name == "labview.exe" {
			return true
		}
		if err := syscall.Process32Next(snapshot, &entry); err != nil {
			break
		}
	}
	return false
}
