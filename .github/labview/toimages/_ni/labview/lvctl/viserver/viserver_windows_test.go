//go:build windows

package viserver

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/go-ole/go-ole"
)

func TestShouldRetryLaunchForClassFactoryError(t *testing.T) {
	err := ole.NewError(0x80040111)
	if !shouldRetryLaunch(err, 1) {
		t.Fatal("expected class factory error to be retryable")
	}
}

func TestShouldNotRetryLaunchOnLastAttempt(t *testing.T) {
	err := ole.NewError(0x80040111)
	if shouldRetryLaunch(err, connectLaunchRetries) {
		t.Fatal("expected no retry on final attempt")
	}
}

func TestShouldRetryLaunchForMatchingErrorText(t *testing.T) {
	err := errors.New("ClassFactory cannot supply requested class")
	if !shouldRetryLaunch(err, 1) {
		t.Fatal("expected matching ClassFactory text to be retryable")
	}
}

func TestShouldNotRetryLaunchForUnrelatedError(t *testing.T) {
	err := errors.New("access denied")
	if shouldRetryLaunch(err, 1) {
		t.Fatal("expected unrelated errors to remain non-retryable")
	}
}

func TestIsClassFactoryError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"OLE 0x80040111", ole.NewError(0x80040111), true},
		{"ClassFactory text", errors.New("ClassFactory cannot supply requested class"), true},
		{"class factory text", errors.New("class factory error"), true},
		{"cannot supply requested class", errors.New("cannot supply requested class"), true},
		{"access denied", errors.New("access denied"), false},
		{"random OLE error", ole.NewError(0x80070005), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isClassFactoryError(tt.err); got != tt.want {
				t.Fatalf("isClassFactoryError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestParseExePath(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			"quoted with flag",
			`"C:\Program Files\NI\LabVIEW 2024\LabVIEW.exe" /Automation`,
			`C:\Program Files\NI\LabVIEW 2024\LabVIEW.exe`,
		},
		{
			"quoted no flag",
			`"C:\Program Files\NI\LabVIEW 2024\LabVIEW.exe"`,
			`C:\Program Files\NI\LabVIEW 2024\LabVIEW.exe`,
		},
		{
			"unquoted with /flag",
			`C:\NI\LabVIEW\LabVIEW.exe /Automation`,
			`C:\NI\LabVIEW\LabVIEW.exe`,
		},
		{
			"unquoted with -flag",
			`C:\NI\LabVIEW\LabVIEW.exe -something`,
			`C:\NI\LabVIEW\LabVIEW.exe`,
		},
		{
			"plain path",
			`C:\NI\LabVIEW\LabVIEW.exe`,
			`C:\NI\LabVIEW\LabVIEW.exe`,
		},
		{
			"leading whitespace",
			`  C:\NI\LabVIEW\LabVIEW.exe  `,
			`C:\NI\LabVIEW\LabVIEW.exe`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseExePath(tt.raw); got != tt.want {
				t.Fatalf("parseExePath(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}

func TestDirectLaunchFallbackSuccess(t *testing.T) {
	origFindExe := findLabVIEWExeFn
	origLaunch := launchLabVIEWProcessFn
	origGetActive := getActiveObjectFn
	origAttach := attachUnknownToSessionFn
	origIsRunning := isLabVIEWRunningFn
	origSleep := sleepFn
	t.Cleanup(func() {
		findLabVIEWExeFn = origFindExe
		launchLabVIEWProcessFn = origLaunch
		getActiveObjectFn = origGetActive
		attachUnknownToSessionFn = origAttach
		isLabVIEWRunningFn = origIsRunning
		sleepFn = origSleep
	})

	isLabVIEWRunningFn = func() bool { return false }
	findLabVIEWExeFn = func() (string, error) {
		return `C:\NI\LabVIEW\LabVIEW.exe`, nil
	}

	var launchedPath string
	launchLabVIEWProcessFn = func(path string) error {
		launchedPath = path
		return nil
	}

	// Simulate LabVIEW registering in ROT after 2 polls.
	pollCount := 0
	getActiveObjectFn = func(progID string) (*ole.IUnknown, error) {
		pollCount++
		if pollCount < 3 {
			return nil, errors.New("not in ROT yet")
		}
		return nil, nil
	}
	attachCalled := false
	attachUnknownToSessionFn = func(session *Session, unknown *ole.IUnknown, launched bool) (*Session, error) {
		attachCalled = true
		if !launched {
			t.Fatal("expected direct launch fallback to mark a launched process")
		}
		if unknown != nil {
			t.Fatalf("expected nil IUnknown from test stub, got %#v", unknown)
		}
		session.launched = launched
		return session, nil
	}

	sleepFn = func(time.Duration) {}

	session := &Session{}
	got, err := directLaunchFallback(session)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != session {
		t.Fatalf("expected returned session to match input session, got %#v", got)
	}
	if launchedPath == "" {
		t.Fatal("expected launchLabVIEWProcessFn to be called")
	}
	if !attachCalled {
		t.Fatal("expected attachUnknownToSessionFn to be called")
	}
	if !session.launched {
		t.Fatal("expected session to be marked launched")
	}
}

func TestDirectLaunchFallbackDoesNotMarkExistingProcessAsLaunched(t *testing.T) {
	origGetActive := getActiveObjectFn
	origAttach := attachUnknownToSessionFn
	origIsRunning := isLabVIEWRunningFn
	origLaunch := launchLabVIEWProcessFn
	origSleep := sleepFn
	t.Cleanup(func() {
		getActiveObjectFn = origGetActive
		attachUnknownToSessionFn = origAttach
		isLabVIEWRunningFn = origIsRunning
		launchLabVIEWProcessFn = origLaunch
		sleepFn = origSleep
	})

	isLabVIEWRunningFn = func() bool { return true }
	launchLabVIEWProcessFn = func(string) error {
		t.Fatal("did not expect direct launch when LabVIEW is already running")
		return nil
	}
	getActiveObjectFn = func(string) (*ole.IUnknown, error) {
		return nil, nil
	}
	attachUnknownToSessionFn = func(session *Session, unknown *ole.IUnknown, launched bool) (*Session, error) {
		if launched {
			t.Fatal("expected existing LabVIEW process to remain unlaunched")
		}
		session.launched = launched
		return session, nil
	}
	sleepFn = func(time.Duration) {}

	session := &Session{}
	got, err := directLaunchFallback(session)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != session {
		t.Fatalf("expected returned session to match input session, got %#v", got)
	}
	if session.launched {
		t.Fatal("expected session.launched to remain false")
	}
}

func TestAttachUnknownToSessionNilUnknownReturnsError(t *testing.T) {
	session := &Session{}

	got, err := attachUnknownToSession(session, nil, false)
	if err == nil {
		t.Fatal("expected error for nil IUnknown")
	}
	if got != nil {
		t.Fatalf("expected nil session result, got %#v", got)
	}
	if !strings.Contains(err.Error(), "nil IUnknown") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDirectLaunchFallbackFindExeFails(t *testing.T) {
	origFindExe := findLabVIEWExeFn
	origIsRunning := isLabVIEWRunningFn
	t.Cleanup(func() {
		findLabVIEWExeFn = origFindExe
		isLabVIEWRunningFn = origIsRunning
	})

	isLabVIEWRunningFn = func() bool { return false }
	findLabVIEWExeFn = func() (string, error) {
		return "", errors.New("registry key not found")
	}

	session := &Session{}
	_, err := directLaunchFallback(session)
	if err == nil {
		t.Fatal("expected error when findLabVIEWExe fails")
	}
	if !strings.Contains(err.Error(), "cannot find LabVIEW.exe") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDirectLaunchFallbackLaunchFails(t *testing.T) {
	origFindExe := findLabVIEWExeFn
	origLaunch := launchLabVIEWProcessFn
	origIsRunning := isLabVIEWRunningFn
	t.Cleanup(func() {
		findLabVIEWExeFn = origFindExe
		launchLabVIEWProcessFn = origLaunch
		isLabVIEWRunningFn = origIsRunning
	})

	isLabVIEWRunningFn = func() bool { return false }
	findLabVIEWExeFn = func() (string, error) {
		return `C:\NI\LabVIEW\LabVIEW.exe`, nil
	}
	launchLabVIEWProcessFn = func(string) error {
		return errors.New("access denied")
	}

	session := &Session{}
	_, err := directLaunchFallback(session)
	if err == nil {
		t.Fatal("expected error when launch fails")
	}
	if !strings.Contains(err.Error(), "access denied") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDirectLaunchFallbackPollTimeout(t *testing.T) {
	origFindExe := findLabVIEWExeFn
	origLaunch := launchLabVIEWProcessFn
	origGetActive := getActiveObjectFn
	origIsRunning := isLabVIEWRunningFn
	origSleep := sleepFn
	origTimeout := directLaunchPollTimeout
	t.Cleanup(func() {
		findLabVIEWExeFn = origFindExe
		launchLabVIEWProcessFn = origLaunch
		getActiveObjectFn = origGetActive
		isLabVIEWRunningFn = origIsRunning
		sleepFn = origSleep
		directLaunchPollTimeout = origTimeout
	})

	directLaunchPollTimeout = 20 * time.Millisecond
	isLabVIEWRunningFn = func() bool { return false }
	findLabVIEWExeFn = func() (string, error) {
		return `C:\NI\LabVIEW\LabVIEW.exe`, nil
	}
	launchLabVIEWProcessFn = func(string) error { return nil }
	getActiveObjectFn = func(string) (*ole.IUnknown, error) {
		return nil, errors.New("not in ROT")
	}
	sleepFn = func(time.Duration) {}

	session := &Session{}
	_, err := directLaunchFallback(session)
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "did not register for COM") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestWaitForAppReadyRetriesUntilProbeSucceeds(t *testing.T) {
	originalGetProperty := getPropertyFn
	originalSleep := sleepFn
	t.Cleanup(func() {
		getPropertyFn = originalGetProperty
		sleepFn = originalSleep
	})

	attempts := 0
	getPropertyFn = func(_ *ole.IDispatch, name string, params ...interface{}) (*ole.VARIANT, error) {
		if name != "Version" {
			t.Fatalf("unexpected property probe: %s", name)
		}
		attempts++
		if attempts < 3 {
			return nil, errors.New("not ready")
		}
		v := ole.NewVariant(ole.VT_I4, 24)
		return &v, nil
	}
	sleepFn = func(time.Duration) {}

	if err := waitForAppReady(nil, 2*time.Second); err != nil {
		t.Fatalf("expected readiness probe to succeed after retries: %v", err)
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

func TestWaitForAppReadyTimesOut(t *testing.T) {
	originalGetProperty := getPropertyFn
	originalSleep := sleepFn
	t.Cleanup(func() {
		getPropertyFn = originalGetProperty
		sleepFn = originalSleep
	})

	getPropertyFn = func(_ *ole.IDispatch, _ string, _ ...interface{}) (*ole.VARIANT, error) {
		return nil, errors.New("not ready")
	}
	sleepFn = func(time.Duration) {}

	err := waitForAppReady(nil, 20*time.Millisecond)
	if err == nil {
		t.Fatal("expected readiness probe to time out")
	}
	if err.Error() == "" {
		t.Fatal("expected timeout error to preserve readiness failure details")
	}
	if want := "did not become automation-ready"; !strings.Contains(err.Error(), want) {
		t.Fatalf("error = %q, want substring %q", err.Error(), want)
	}
}

func TestEnsureAutomaticCloseDisabledSetsFalse(t *testing.T) {
	originalPutProperty := putPropertyFn
	t.Cleanup(func() {
		putPropertyFn = originalPutProperty
	})

	called := false
	putPropertyFn = func(_ *ole.IDispatch, name string, params ...interface{}) (*ole.VARIANT, error) {
		called = true
		if name != "AutomaticClose" {
			t.Fatalf("unexpected property name: %s", name)
		}
		if len(params) != 1 {
			t.Fatalf("expected one property value, got %d", len(params))
		}
		value, ok := params[0].(bool)
		if !ok {
			t.Fatalf("expected bool property value, got %T", params[0])
		}
		if value {
			t.Fatal("expected AutomaticClose to be set false")
		}
		v := ole.NewVariant(ole.VT_BOOL, 0)
		return &v, nil
	}

	session := &Session{app: &ole.IDispatch{}}
	if err := session.ensureAutomaticCloseDisabled(); err != nil {
		t.Fatalf("ensureAutomaticCloseDisabled() error = %v", err)
	}
	if !called {
		t.Fatal("expected AutomaticClose property write")
	}
}

func TestEnsureAutomaticCloseDisabledWrapsError(t *testing.T) {
	originalPutProperty := putPropertyFn
	t.Cleanup(func() {
		putPropertyFn = originalPutProperty
	})

	putPropertyFn = func(_ *ole.IDispatch, _ string, _ ...interface{}) (*ole.VARIANT, error) {
		return nil, errors.New("access denied")
	}

	session := &Session{app: &ole.IDispatch{}}
	err := session.ensureAutomaticCloseDisabled()
	if err == nil {
		t.Fatal("expected ensureAutomaticCloseDisabled to fail")
	}
	if want := `set application property "AutomaticClose": access denied`; fmt.Sprint(err) != want {
		t.Fatalf("error = %q, want %q", err, want)
	}
}
