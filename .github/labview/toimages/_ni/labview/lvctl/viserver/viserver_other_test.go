//go:build !windows

package viserver

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWaitForHandshakeRetriesUntilSuccess(t *testing.T) {
	origDial := dialTCPTimeoutFn
	t.Cleanup(func() {
		dialTCPTimeoutFn = origDial
	})

	attempts := 0
	dialTCPTimeoutFn = func(addr string, timeoutDuration time.Duration) (*tcpConn, error) {
		attempts++
		if addr != "127.0.0.1:3363" {
			t.Fatalf("addr = %q, want %q", addr, "127.0.0.1:3363")
		}
		if timeoutDuration <= 0 {
			t.Fatalf("timeoutDuration = %v, want positive", timeoutDuration)
		}
		if attempts < 3 {
			return nil, errors.New("server rejected connection: error 63")
		}
		return &tcpConn{}, nil
	}

	tc, err := waitForHandshake(context.Background(), "127.0.0.1:3363")
	if err != nil {
		t.Fatalf("waitForHandshake() error = %v", err)
	}
	if tc == nil {
		t.Fatal("waitForHandshake() = nil tcpConn, want non-nil")
	}
	if attempts != 3 {
		t.Fatalf("attempts = %d, want 3", attempts)
	}
}

func TestWaitForHandshakeReportsLastErrorOnTimeout(t *testing.T) {
	origDial := dialTCPTimeoutFn
	t.Cleanup(func() {
		dialTCPTimeoutFn = origDial
	})

	dialTCPTimeoutFn = func(string, time.Duration) (*tcpConn, error) {
		return nil, errors.New("server rejected connection: error 63")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	tc, err := waitForHandshake(ctx, "127.0.0.1:3363")
	if err == nil {
		t.Fatal("waitForHandshake() error = nil, want error")
	}
	if tc != nil {
		t.Fatalf("waitForHandshake() tcpConn = %#v, want nil", tc)
	}
	if got := err.Error(); got != "timeout waiting for 127.0.0.1:3363: context canceled (last error: server rejected connection: error 63)" {
		t.Fatalf("waitForHandshake() error = %q", got)
	}
}
