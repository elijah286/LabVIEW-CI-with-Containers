//go:build !windows

package viserver

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

var dialTCPTimeoutFn = dialTCPTimeout

// Well-known property/method selectors from objsels.h.
const (
	viExecStateAttr    int32 = 557
	viPrefExecSysAttr  int32 = 0x22F // kVIPrefExecSysAttr (Exec.PrefSys)
	viRunMethod        int32 = 1003
	viAbortMethod      int32 = 1004
	viSetCtrlValFlat   int32 = 1009
	viGetCtrlValFlat   int32 = 1010
	viSetCtrlVariant   int32 = 1051
	viGetCtrlVariant   int32 = 1052
)

// ExecState values returned by kVIExecStateAttr.
const (
	execStateIdle    int32 = 1
	execStateRunning int32 = 2
	execStateBad     int32 = 5
)

// Preferred execution system values for kVIPrefExecSysAttr.
const (
	prefExecSysUI     int32 = 1 // kVIRefECUI — run on the UI thread
	prefExecSysNormal int32 = 2 // kVIRefECNormal
)

// Session holds a TCP connection to LabVIEW's VI Server (port 3363).
type Session struct {
	tcp      *tcpConn
	proc     *os.Process // non-nil if we launched LabVIEW
	launched bool        // true if we started LabVIEW (vs attaching to existing)
}

// Connect connects to a running LabVIEW VI Server, or launches LabVIEW if
// one is not already listening. This mirrors the Windows COM behavior where
// CreateObject either attaches or launches.
//
// Environment variables:
//   - LABVIEW_HOST — override the default "127.0.0.1:3363"
//   - LABVIEW_PATH — LabVIEW install directory (e.g. "/usr/local/natinst/LabVIEW-2026-64");
//     auto-detected if not set
func Connect() (*Session, error) {
	addr := viServerAddr()

	// Try to connect to an existing LabVIEW instance first. A TCP dial with a
	// short timeout is cheap — if VI Server is listening this completes in
	// milliseconds.
	tc, err := dialTCPTimeout(addr, 2*time.Second)
	if err == nil {
		slog.Debug("Attached to existing LabVIEW instance", "addr", addr)
		return &Session{tcp: tc}, nil
	}
	slog.Debug("No existing LabVIEW VI Server found, launching...", "addr", addr, "err", err)

	// Launch LabVIEW.
	proc, err := launchLabVIEW()
	if err != nil {
		return nil, fmt.Errorf("failed to launch LabVIEW: %w", err)
	}

	// Wait for VI Server to accept the full handshake, not just the TCP port.
	// LabVIEW can listen before the VI Server transport is ready to talk.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	tc, err = waitForHandshake(ctx, addr)
	if err != nil {
		// Clean up the process we started.
		_ = proc.Kill()
		return nil, fmt.Errorf("LabVIEW started (pid %d) but VI Server handshake did not succeed: %w", proc.Pid, err)
	}

	slog.Info("Connected to newly launched LabVIEW", "pid", proc.Pid, "addr", addr)
	return &Session{tcp: tc, proc: proc, launched: true}, nil
}

// viServerAddr returns the VI Server TCP address to connect to.
func viServerAddr() string {
	if addr := os.Getenv("LABVIEW_HOST"); addr != "" {
		return addr
	}
	return fmt.Sprintf("127.0.0.1:%d", DefaultVIServerPort)
}

// dialTCPTimeout is like dialTCP but with a connection timeout.
func dialTCPTimeout(addr string, timeout time.Duration) (*tcpConn, error) {
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	tc := &tcpConn{conn: conn}
	tc.nextID.Store(1)
	if err := tc.handshake(); err != nil {
		conn.Close()
		return nil, err
	}
	return tc, nil
}

// waitForHandshake polls until VI Server accepts a full handshake.
func waitForHandshake(ctx context.Context, addr string) (*tcpConn, error) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	var lastErr error
	for {
		tc, err := dialTCPTimeoutFn(addr, 10*time.Second)
		if err == nil {
			return tc, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			if lastErr != nil {
				return nil, fmt.Errorf("timeout waiting for %s: %w (last error: %v)", addr, ctx.Err(), lastErr)
			}
			return nil, fmt.Errorf("timeout waiting for %s: %w", addr, ctx.Err())
		case <-ticker.C:
		}
	}
}

// launchLabVIEW finds and starts the LabVIEW executable. VI Server TCP must be
// enabled in LabVIEW's configuration (server.tcp.enabled=True in labview.ini)
// for the TCP port to become available after launch.
func launchLabVIEW() (*os.Process, error) {
	exePath, err := findLabVIEW()
	if err != nil {
		return nil, err
	}

	// Pass `-pref <config>` when LABVIEW_CONF is set so a headless/container
	// launch can enable VI Server TCP and suppress dialogs from a checked-in
	// config, without relying on the install's default labview.conf location.
	// Env-gated: when LABVIEW_CONF is unset this is exactly the upstream launch.
	// (vi-browser CI addition.)
	var args []string
	if conf := os.Getenv("LABVIEW_CONF"); conf != "" {
		args = append(args, "-pref", conf)
	}
	slog.Info("Starting LabVIEW", "executable", exePath, "args", args)
	cmd := exec.Command(exePath, args...)
	// LabVIEW is left running for later attach, so it must NOT inherit and hold
	// the caller's stdout/stderr: a parent that captures this process's output
	// (e.g. a batch runner doing exec + output capture) would otherwise block
	// forever in Wait() on the pipe LabVIEW keeps open. When LABVIEW_LOG is set,
	// detach LabVIEW's output to that file; otherwise keep the upstream behavior.
	// (vi-browser CI addition; env-gated.)
	if logPath := os.Getenv("LABVIEW_LOG"); logPath != "" {
		if f, ferr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); ferr == nil {
			cmd.Stdout = f
			cmd.Stderr = f
			defer f.Close()
		} else {
			slog.Warn("could not open LABVIEW_LOG; discarding LabVIEW output", "path", logPath, "error", ferr)
		}
	} else {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("exec %s: %w", exePath, err)
	}
	slog.Info("LabVIEW process started", "pid", cmd.Process.Pid)
	return cmd.Process, nil
}

// findLabVIEW locates the LabVIEW executable. Checks, in order:
//  1. LABVIEW_PATH environment variable
//  2. Common install locations for the current OS
func findLabVIEW() (string, error) {
	if p := os.Getenv("LABVIEW_PATH"); p != "" {
		exe := labviewExePath(p)
		if _, err := os.Stat(exe); err == nil {
			return exe, nil
		}
		return "", fmt.Errorf("LABVIEW_PATH set to %q but executable not found at %s", p, exe)
	}

	// Auto-detect from common install locations.
	candidates := labviewSearchPaths()
	for _, exe := range candidates {
		if _, err := os.Stat(exe); err == nil {
			slog.Debug("Auto-detected LabVIEW", "path", exe)
			return exe, nil
		}
	}

	return "", fmt.Errorf("LabVIEW not found; set LABVIEW_PATH to the install directory")
}

// labviewExePath returns the full path to the LabVIEW executable given an
// install directory. On macOS, it checks for both the standard and Community
// Edition app bundle names.
func labviewExePath(installDir string) string {
	if runtime.GOOS == "darwin" {
		// Community Edition uses "LabVIEWCommunity.app"; check it first since
		// it's the more common free download, then fall back to the standard name.
		for _, app := range []struct{ bundle, exe string }{
			{"LabVIEWCommunity.app", "LabVIEWCommunity"},
			{"LabVIEW.app", "LabVIEW"},
		} {
			p := filepath.Join(installDir, app.bundle, "Contents", "MacOS", app.exe)
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
		// Default to the standard name so callers get a meaningful "not found" path.
		return filepath.Join(installDir, "LabVIEW.app", "Contents", "MacOS", "LabVIEW")
	}
	return filepath.Join(installDir, "labview")
}

// labviewSearchPaths returns candidate LabVIEW executable paths for the
// current OS, with newer versions preferred.
func labviewSearchPaths() []string {
	var paths []string
	switch runtime.GOOS {
	case "linux":
		// NI standard install locations: /usr/local/natinst/LabVIEW-<version>
		base := "/usr/local/natinst"
		entries, err := os.ReadDir(base)
		if err == nil {
			var dirs []string
			for _, e := range entries {
				if e.IsDir() && strings.HasPrefix(e.Name(), "LabVIEW-") {
					dirs = append(dirs, e.Name())
				}
			}
			// Sort descending so newest version is tried first.
			sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
			for _, d := range dirs {
				paths = append(paths, filepath.Join(base, d, "labview"))
			}
		}

	case "darwin":
		// macOS: /Applications/National Instruments/LabVIEW <version>
		// Supports both standard (LabVIEW.app) and Community Edition
		// (LabVIEWCommunity.app) app bundles.
		base := "/Applications/National Instruments"
		entries, err := os.ReadDir(base)
		if err == nil {
			var dirs []string
			for _, e := range entries {
				if e.IsDir() && strings.HasPrefix(e.Name(), "LabVIEW") {
					dirs = append(dirs, e.Name())
				}
			}
			sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
			for _, d := range dirs {
				paths = append(paths, filepath.Join(base, d, "LabVIEWCommunity.app", "Contents", "MacOS", "LabVIEWCommunity"))
				paths = append(paths, filepath.Join(base, d, "LabVIEW.app", "Contents", "MacOS", "LabVIEW"))
			}
		}
	}
	return paths
}

// Close disconnects from VI Server. If we launched LabVIEW, the process is
// left running (matching the Windows behavior where LabVIEW is minimized but
// not killed). Call Kill() to terminate a launched instance.
func (s *Session) Close() {
	if s.tcp != nil {
		s.tcp.close()
		s.tcp = nil
	}
}

// Kill terminates a LabVIEW process that was launched by Connect(). No-op if
// we attached to an already-running instance.
func (s *Session) Kill() error {
	if s.proc == nil {
		return nil
	}
	slog.Info("Terminating LabVIEW process", "pid", s.proc.Pid)
	if err := s.proc.Kill(); err != nil {
		return fmt.Errorf("kill LabVIEW (pid %d): %w", s.proc.Pid, err)
	}
	_, _ = s.proc.Wait() // reap to avoid zombies
	s.proc = nil
	return nil
}

// OpenVIFrontPanel opens a VI's front panel via property 30 (kVIFPStateAttr).
// This loads the front panel bitmap into memory, which is required for image
// capture operations via LabVIEW scripting.
func (s *Session) OpenVIFrontPanel(viPath string) error {
	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return fmt.Errorf("openVIRef %s: %w", viPath, err)
	}
	defer s.tcp.releaseRef(viRef)

	// Property 30 (0x1E) = kVIFPStateAttr. Value 5 = Standard (shown at normal size).
	const viFPStateAttr int32 = 30
	const fpStateStandard int32 = 5
	td := makeTDSimple(tcI32)
	data := make([]byte, 4)
	be.PutUint32(data, uint32(fpStateStandard))
	if err := s.tcp.setVIProperty(viRef, viFPStateAttr, td, data); err != nil {
		return fmt.Errorf("set FP state: %w", err)
	}
	slog.Debug("Opened VI front panel", "viPath", viPath)
	return nil
}

// RunVIRaw is like RunVI but returns the raw variant payload bytes for each
// indicator instead of unflattening them. Useful for debugging.
func (s *Session) RunVIRaw(timeout time.Duration, viPath string, controls map[string]any, indicatorNames []string, searchDirs ...string) (map[string][]byte, error) {
	for _, dir := range searchDirs {
		if err := s.addSearchPath(dir); err != nil {
			slog.Warn("failed to add search path", "dir", dir, "error", err)
		}
	}

	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return nil, fmt.Errorf("open VI %s: %w", viPath, err)
	}
	defer s.tcp.releaseRef(viRef)

	for name, value := range controls {
		if err := s.setControlValue(viRef, name, value); err != nil {
			return nil, fmt.Errorf("set control %q: %w", name, err)
		}
	}

	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	if err := s.setPrefExecSys(viRef, prefExecSysUI); err != nil {
		slog.Warn("failed to set preferred exec system to UI", "error", err)
	}
	if err := s.runVI(viRef, timeout); err != nil {
		return nil, fmt.Errorf("run VI: %w", err)
	}

	// Read raw variant payloads.
	result := make(map[string][]byte, len(indicatorNames))
	for _, name := range indicatorNames {
		raw, err := s.getControlValueRaw(viRef, name)
		if err != nil {
			return nil, fmt.Errorf("read indicator %q: %w", name, err)
		}
		result[name] = raw
	}
	return result, nil
}

// getControlValueRaw is like getControlValue but returns the raw variant bytes.
func (s *Session) getControlValueRaw(viRef uint32, name string) ([]byte, error) {
	nameData, err := flattenData(name)
	if err != nil {
		return nil, err
	}

	respBody, err := s.tcp.invokeVIMethod(
		viRef,
		viMethodGetCtrlValVariantSpec,
		viMethodArg{},
		viMethodArg{data: nameData},
	)
	if err != nil {
		return nil, err
	}

	resultIndex, err := viMethodGetCtrlValVariantSpec.responseIndex(0)
	if err != nil {
		return nil, err
	}
	payload, err := extractMethodParamPayload(respBody, resultIndex, "getControlValueRaw")
	if err != nil {
		return nil, err
	}
	return payload, nil
}

// GetVIPropertyByID opens a VI and reads a property by numeric ID, returning
// the raw response body for inspection.
func (s *Session) GetVIPropertyByID(viPath string, propID int32) ([]byte, error) {
	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return nil, fmt.Errorf("openVIRef: %w", err)
	}
	defer s.tcp.releaseRef(viRef)

	body, err := s.tcp.getVIProperty(viRef, propID)
	if err != nil {
		return nil, err
	}
	return body, nil
}

// GetVIPropertyByIDWithTD opens a VI and reads a property by numeric ID,
// passing a type descriptor hint so the server knows what data format to return.
// Without a TD, many properties return paramSize=0 (empty data).
func (s *Session) GetVIPropertyByIDWithTD(viPath string, propID int32, td []byte) ([]byte, error) {
	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return nil, fmt.Errorf("openVIRef: %w", err)
	}
	defer s.tcp.releaseRef(viRef)

	body, err := s.tcp.getVIProperty(viRef, propID, td)
	if err != nil {
		return nil, err
	}
	return body, nil
}

// kVICalleesPathsAttr is the VI property that returns file paths of all callees
// (SubVIs, type defs, etc.). Defined in objsels.h as property 640.
const kVICalleesPathsAttr int32 = 640

// GetVICalleesPaths opens a VI and reads its callee file paths via property 640.
// Returns a slice of absolute paths to all SubVIs and other dependencies that
// the VI directly references. This is useful for dynamically discovering which
// directories need to be in LabVIEW's search path.
func (s *Session) GetVICalleesPaths(viPath string) ([]string, error) {
	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return nil, fmt.Errorf("openVIRef %s: %w", viPath, err)
	}
	defer s.tcp.releaseRef(viRef)

	td := makeTDPathArray()
	body, err := s.tcp.getVIProperty(viRef, kVICalleesPathsAttr, td)
	if err != nil {
		return nil, fmt.Errorf("get callees paths: %w", err)
	}

	paths, err := extractPropertyPathArray(body)
	if err != nil {
		return nil, fmt.Errorf("parse callees paths: %w", err)
	}
	return paths, nil
}

// RunVI opens a VI, sets controls, runs it, waits for completion, and reads indicators.
func (s *Session) RunVI(timeout time.Duration, viPath string, controls map[string]any, indicatorNames []string, searchDirs ...string) (map[string]any, error) {
	slog.Debug("RunVI", "viPath", viPath, "controls", len(controls), "indicators", len(indicatorNames))

	// Best-effort: add caller-specified directories to LabVIEW's search paths.
	// This is non-fatal — SubVIs co-located with the caller VI are found
	// automatically. Matches the Windows implementation which warns on failure.
	for _, dir := range searchDirs {
		if err := s.addSearchPath(dir); err != nil {
			slog.Warn("failed to add search path", "dir", dir, "error", err)
		}
	}

	viRef, err := s.tcp.openVIRef(viPath)
	if err != nil {
		return nil, fmt.Errorf("open VI %s: %w", viPath, err)
	}
	defer s.tcp.releaseRef(viRef)

	// Set control values.
	for name, value := range controls {
		if err := s.setControlValue(viRef, name, value); err != nil {
			return nil, fmt.Errorf("set control %q: %w", name, err)
		}
	}

	if timeout <= 0 {
		timeout = 2 * time.Minute
	}

	// Force the VI to run on the UI execution system. Image capture and
	// other front-panel operations require the UI thread on macOS.
	if err := s.setPrefExecSys(viRef, prefExecSysUI); err != nil {
		slog.Warn("failed to set preferred exec system to UI", "error", err)
	}

	slog.Debug("Run VI start", "viRef", viRef)
	start := time.Now()
	if err := s.runVI(viRef, timeout); err != nil {
		return nil, fmt.Errorf("run VI: %w", err)
	}
	slog.Debug("VI execution complete", "elapsed", time.Since(start))

	// Read indicator values.
	result := make(map[string]any, len(indicatorNames))
	for _, name := range indicatorNames {
		val, err := s.getControlValue(viRef, name)
		if err != nil {
			return nil, fmt.Errorf("read indicator %q: %w", name, err)
		}
		result[name] = val
	}
	return result, nil
}

// ---------- Control value get/set via VI methods ----------

// setControlValue uses the variant setter path, which matches LabVIEW's
// VIRefSetControlValueFromC helper.
func (s *Session) setControlValue(viRef uint32, name string, value any) error {
	variantData, err := flattenVariant(value, s.tcp.version)
	if err != nil {
		return err
	}

	nameData, err := flattenData(name)
	if err != nil {
		return err
	}

	_, err = s.tcp.invokeVIMethod(
		viRef,
		viMethodSetCtrlValVariantSpec,
		viMethodArg{},
		viMethodArg{data: nameData},
		viMethodArg{data: variantData},
	)
	return err
}

// getControlValue calls kVIMGetCtrlValVariant and returns a Go value.
func (s *Session) getControlValue(viRef uint32, name string) (any, error) {
	nameData, err := flattenData(name)
	if err != nil {
		return nil, err
	}

	respBody, err := s.tcp.invokeVIMethod(
		viRef,
		viMethodGetCtrlValVariantSpec,
		viMethodArg{},
		viMethodArg{data: nameData},
	)
	if err != nil {
		return nil, err
	}

	resultIndex, err := viMethodGetCtrlValVariantSpec.responseIndex(0)
	if err != nil {
		return nil, err
	}
	return extractMethodVariantResult(respBody, resultIndex, "getControlValue data")
}

// getExecState reads the ExecState property of a VI.
func (s *Session) getExecState(viRef uint32) (int32, error) {
	// Pass I32 TD so the server includes actual data in the response.
	// Without a TD, the server returns paramSize=0 even when the property is readable.
	td := makeTDSimple(tcI32)
	body, err := s.tcp.getVIProperty(viRef, viExecStateAttr, td)
	if err != nil {
		return 0, err
	}
	state, err := extractPropertyI32Result(body)
	if err != nil {
		return 0, fmt.Errorf("read ExecState: %w", err)
	}
	slog.Debug("getExecState", "viRef", viRef, "state", state)
	return state, nil
}

func (s *Session) runVI(viRef uint32, timeout time.Duration) error {
	// Use Run with Wait Until Done? = true. The TCP server blocks until the VI
	// finishes executing and then sends the response. We set a TCP read deadline
	// matching the caller's timeout so the call doesn't hang forever.
	trueData, err := flattenData(true)
	if err != nil {
		return err
	}
	falseData, err := flattenData(false)
	if err != nil {
		return err
	}
	slog.Debug("runVI invoking (wait=true)", "viRef", viRef, "timeout", timeout)
	// Run with Wait Until Done? = true, Auto Dispose Ref? = false.
	_, err = s.tcp.invokeVIMethodWithTimeout(
		viRef,
		viMethodRunInstrumentSpec,
		timeout,
		viMethodArg{data: trueData},  // Wait Until Done? = true
		viMethodArg{data: falseData}, // Auto Dispose Ref? = false
	)
	if err != nil {
		return err
	}
	slog.Debug("runVI completed", "viRef", viRef)
	return nil
}

func (s *Session) abortVI(viRef uint32) error {
	_, err := s.tcp.invokeVIMethod(viRef, viMethodAbortSpec)
	return err
}

// kAppSearchPathAttr is the Application property for LabVIEW's VI search paths.
// It holds a 1D array of absolute paths. Defined in objsels.h.
const kAppSearchPathAttr int32 = 88

// addSearchPath appends a directory to LabVIEW's VI search paths via
// Application property 88 (kAppSearchPathAttr). The property is a 1D array
// of paths, so we perform get-modify-set: read current paths, append the new
// directory if not already present, and write the modified array back.
func (s *Session) addSearchPath(dir string) error {
	// GET current search paths. We send the path-array TD so the server
	// allocates data and actually executes the property GET. Without a TD
	// (paramSize=0), the server skips the entry because data is null.
	td := makeTDPathArray()
	body, err := s.tcp.getAppPropertyWithTD(kAppSearchPathAttr, td)
	if err != nil {
		return fmt.Errorf("get search paths: %w", err)
	}

	serverTD, currentPaths, err := extractPropertyPathArrayWithTD(body)
	if err != nil {
		return fmt.Errorf("parse search paths: %w", err)
	}

	// Check if dir is already in the search paths.
	for _, p := range currentPaths {
		if p == dir {
			return nil // already present
		}
	}

	// Append the new directory and SET using the server's response TD.
	// The server re-flattens our TD in the response; using it ensures
	// byte-level compatibility with what the server expects.
	newPaths := append(currentPaths, dir)
	data, err := flattenPathArray(newPaths)
	if err != nil {
		return fmt.Errorf("flatten search paths: %w", err)
	}

	// Use the server's response TD if available; fall back to our generated TD.
	setTD := serverTD
	if len(setTD) == 0 {
		setTD = td
	}

	err = s.tcp.setAppProperty(kAppSearchPathAttr, setTD, data)
	if err != nil {
		return fmt.Errorf("set search paths: %w", err)
	}
	return nil
}

// setPrefExecSys sets the VI's preferred execution system. Use prefExecSysUI
// to force execution on the UI thread (required for image capture on macOS).
func (s *Session) setPrefExecSys(viRef uint32, execSys int32) error {
	td := makeTDSimple(tcI32)
	data := make([]byte, 4)
	be.PutUint32(data, uint32(execSys))
	return s.tcp.setVIProperty(viRef, viPrefExecSysAttr, td, data)
}

func extractPropertyI32Result(body []byte) (int32, error) {
	// Property response format (from CliRcvPropVector):
	//   nEntries(4) + errIdxOut(4) + idxSpecificErrOut(4)
	//   Per entry: flags(4) + selector(4) + paramSize(4) + paramData(paramSize)
	//   Trailing: PStr error string (1+ bytes)
	if len(body) < 24 {
		return 0, fmt.Errorf("property response too short (%d bytes)", len(body))
	}
	nEntries := int(be.Uint32(body[0:4]))
	if nEntries < 1 {
		return 0, fmt.Errorf("property response missing entries")
	}
	idxSpecificErr := int32(be.Uint32(body[8:12]))
	if idxSpecificErr != 0 {
		return 0, fmt.Errorf("property error: idxSpecificErr=%d", idxSpecificErr)
	}
	// flags at [12:16], selector at [16:20]
	paramSize := int(be.Uint32(body[20:24]))
	paramStart := 24
	if paramSize == 0 {
		return 0, fmt.Errorf("property returned no data (paramSize=0)")
	}
	if len(body) < paramStart+paramSize {
		return 0, fmt.Errorf("property response truncated")
	}
	paramData := body[paramStart : paramStart+paramSize]
	tdLen := int(be.Uint32(paramData))
	dataStart := 4 + tdLen
	if len(paramData) < dataStart+4 {
		return 0, fmt.Errorf("property data truncated (need %d, have %d)", dataStart+4, len(paramData))
	}
	return int32(be.Uint32(paramData[dataStart:])), nil
}

// extractPropertyPathArray parses a property response containing a 1D path array.
// Uses the same response format as extractPropertyI32Result but unflattens paths.
func extractPropertyPathArray(body []byte) ([]string, error) {
	_, paths, err := extractPropertyPathArrayWithTD(body)
	return paths, err
}

// extractPropertyPathArrayWithTD parses a property response containing a 1D
// path array and also returns the raw TD bytes from the server's response.
// The returned TD can be reused for SET operations to avoid TD mismatches.
func extractPropertyPathArrayWithTD(body []byte) ([]byte, []string, error) {
	if len(body) < 24 {
		return nil, nil, fmt.Errorf("property response too short (%d bytes)", len(body))
	}
	nEntries := int(be.Uint32(body[0:4]))
	if nEntries < 1 {
		return nil, nil, fmt.Errorf("property response missing entries")
	}
	idxSpecificErr := int32(be.Uint32(body[8:12]))
	if idxSpecificErr != 0 {
		return nil, nil, fmt.Errorf("property error: idxSpecificErr=%d", idxSpecificErr)
	}
	paramSize := int(be.Uint32(body[20:24]))
	paramStart := 24
	if paramSize == 0 {
		// Empty response — return empty path list with no TD.
		return nil, nil, nil
	}
	if len(body) < paramStart+paramSize {
		return nil, nil, fmt.Errorf("property response truncated")
	}
	paramData := body[paramStart : paramStart+paramSize]
	// paramData = [U32 tdLen][bytes td][bytes data]
	if len(paramData) < 4 {
		return nil, nil, fmt.Errorf("property param too short for TD length")
	}
	tdLen := int(be.Uint32(paramData))
	dataStart := 4 + tdLen
	if len(paramData) < dataStart {
		return nil, nil, fmt.Errorf("property TD truncated")
	}
	// Extract raw TD bytes (without the length prefix) for reuse in SET.
	serverTD := paramData[4:dataStart]
	data := paramData[dataStart:]
	paths, err := unflattenPathArray(data)
	if err != nil {
		return nil, nil, err
	}
	return serverTD, paths, nil
}

func extractMethodVariantResult(body []byte, index int, label string) (any, error) {
	payload, err := extractMethodParamPayload(body, index, label)
	if err != nil {
		return nil, err
	}
	if len(payload) < 4 {
		return nil, fmt.Errorf("%s: missing TD length", label)
	}
	tdLen := int(be.Uint32(payload[:4]))
	if len(payload) < 4+tdLen {
		return nil, fmt.Errorf("%s: TD truncated", label)
	}
	data := payload[4+tdLen:]
	return unflattenVariant(data)
}

func extractMethodParamPayload(body []byte, index int, label string) ([]byte, error) {
	if index < 0 {
		return nil, fmt.Errorf("%s: invalid index", label)
	}
	if len(body) < 4 {
		return nil, fmt.Errorf("%s: response too short", label)
	}
	nEntries := int(be.Uint32(body))
	if index >= nEntries {
		return nil, fmt.Errorf("%s: missing result %d of %d", label, index, nEntries)
	}
	off := 4
	for i := 0; i < nEntries; i++ {
		if len(body) < off+8 {
			return nil, fmt.Errorf("%s: truncated entry header", label)
		}
		paramSize := int(be.Uint32(body[off+4:]))
		off += 8
		if len(body) < off+paramSize {
			return nil, fmt.Errorf("%s: truncated entry payload", label)
		}
		if i == index {
			return body[off : off+paramSize], nil
		}
		off += paramSize
	}
	return nil, fmt.Errorf("%s: result not found", label)
}

func flattenVariant(value any, version uint32) ([]byte, error) {
	td, data, err := flattenValue(value)
	if err != nil {
		return nil, err
	}

	var buf []byte
	buf = binary.BigEndian.AppendUint32(buf, version)
	buf = append(buf, td...)
	buf = append(buf, data...)
	buf = binary.BigEndian.AppendUint32(buf, 0)
	return buf, nil
}

func unflattenVariant(buf []byte) (any, error) {
	if len(buf) < 4 {
		return nil, fmt.Errorf("variant payload too short")
	}
	buf = buf[4:]
	entries, rootIdx, tdSize, err := parseFlatTDRWithSize(buf)
	if err != nil {
		return nil, fmt.Errorf("variant TD: %w", err)
	}
	if len(buf) < tdSize+4 {
		return nil, fmt.Errorf("variant payload truncated")
	}
	value, used, err := unflattenFromTD(entries, rootIdx, buf[tdSize:])
	if err != nil {
		return nil, fmt.Errorf("variant data: %w", err)
	}
	attrs := buf[tdSize+used:]
	if len(attrs) < 4 {
		return nil, fmt.Errorf("variant attributes truncated")
	}
	return value, nil
}

func extractMethodStringResult(body []byte, index int, label string) (string, error) {
	if index < 0 {
		return "", fmt.Errorf("%s: invalid index", label)
	}
	if len(body) < 4 {
		return "", fmt.Errorf("%s: response too short", label)
	}
	nEntries := int(be.Uint32(body))
	if index >= nEntries {
		return "", fmt.Errorf("%s: missing result %d of %d", label, index, nEntries)
	}
	off := 4
	for i := 0; i < nEntries; i++ {
		if len(body) < off+8 {
			return "", fmt.Errorf("%s: truncated entry header", label)
		}
		_ = be.Uint32(body[off:])
		paramSize := int(be.Uint32(body[off+4:]))
		off += 8
		if len(body) < off+paramSize {
			return "", fmt.Errorf("%s: truncated entry payload", label)
		}
		if i == index {
			payload := body[off : off+paramSize]
			if len(payload) < 4 {
				return "", fmt.Errorf("%s: missing TD length", label)
			}
			tdLen := int(be.Uint32(payload))
			if len(payload) < 4+tdLen {
				return "", fmt.Errorf("%s: TD truncated", label)
			}
			data := payload[4+tdLen:]
			if len(data) < 4 {
				return "", fmt.Errorf("%s: string payload too short", label)
			}
			n := int(be.Uint32(data))
			if len(data) < 4+n {
				return "", fmt.Errorf("%s: string payload truncated", label)
			}
			return string(data[4 : 4+n]), nil
		}
		off += paramSize
	}
	return "", fmt.Errorf("%s: result not found", label)
}

// ---------- Generic property/method passthroughs ----------
//
// These match the Windows COM interface signatures but operate over TCP.
// Property names are not directly supported by the binary protocol (which
// uses numeric selectors), so callers must use numeric IDs.

func (s *Session) GetAppProperty(name string) (interface{}, error) {
	return nil, fmt.Errorf("GetAppProperty by name not supported over TCP; use numeric property IDs")
}

func (s *Session) SetAppProperty(name string, value interface{}) error {
	return fmt.Errorf("SetAppProperty by name not supported over TCP; use numeric property IDs")
}

func (s *Session) CallAppMethod(name string, args ...interface{}) (interface{}, error) {
	return nil, fmt.Errorf("CallAppMethod by name not supported over TCP; use numeric method IDs")
}

func (s *Session) GetVIProperty(viPath string, name string) (interface{}, error) {
	return nil, fmt.Errorf("GetVIProperty by name not supported over TCP; use numeric property IDs")
}

func (s *Session) SetVIProperty(viPath string, name string, value interface{}) error {
	return fmt.Errorf("SetVIProperty by name not supported over TCP; use numeric property IDs")
}

func (s *Session) CallVIMethod(viPath string, name string, args ...interface{}) (interface{}, error) {
	return nil, fmt.Errorf("CallVIMethod by name not supported over TCP; use numeric method IDs")
}
