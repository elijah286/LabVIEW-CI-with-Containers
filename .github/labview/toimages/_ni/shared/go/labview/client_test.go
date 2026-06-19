package labview

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestLabVIEWError_Error(t *testing.T) {
	err := &LabVIEWError{
		Code:   1059,
		Source: "Unexpected file type",
	}

	expected := "LabVIEW Error 1059: Unexpected file type"
	if err.Error() != expected {
		t.Errorf("Error() = %q, want %q", err.Error(), expected)
	}
}

func TestLabVIEWInputError_Error(t *testing.T) {
	err := &LabVIEWInputError{
		LabVIEWError: LabVIEWError{
			Code:   -2628,
			Source: "Invalid XML",
		},
	}

	expected := "LabVIEW Error -2628: Invalid XML"
	if err.Error() != expected {
		t.Errorf("Error() = %q, want %q", err.Error(), expected)
	}
}

func TestNewClient(t *testing.T) {
	client := NewClient("192.168.1.100", 2552, 10*1024*1024)

	if client == nil {
		t.Fatal("NewClient() = nil, want non-nil")
	}
	if client.address != "192.168.1.100" {
		t.Errorf("address = %q, want \"192.168.1.100\"", client.address)
	}
	if client.port != 2552 {
		t.Errorf("port = %d, want 2552", client.port)
	}
	if client.conn != nil {
		t.Error("conn should be nil before Connect()")
	}
	if client.maxMessageSize != 20*1024*1024 {
		t.Errorf("maxMessageSize = %d, want %d (2x maxFileSizeBytes)", client.maxMessageSize, 20*1024*1024)
	}
}

func TestClient_Close_NotConnected(t *testing.T) {
	client := NewClient("localhost", 2552, 10*1024*1024)

	err := client.Close()
	if err != nil {
		t.Errorf("Close() on unconnected client = %v, want nil", err)
	}
}

func TestClient_RunVISynchronous_NotConnected(t *testing.T) {
	client := NewClient("localhost", 2552, 10*1024*1024)

	_, err := client.RunVISynchronous(context.Background(), "test.vi", nil, 0, false, nil, -1)
	if err == nil {
		t.Fatal("RunVISynchronous() on unconnected client = nil, want error")
	}
	if !strings.Contains(err.Error(), "not connected") {
		t.Errorf("error = %q, want to contain %q", err.Error(), "not connected")
	}
}

func TestPing_InvalidAddress(t *testing.T) {
	// Use a non-routable IP to ensure connection fails quickly
	err := Ping("192.0.2.1", 9999, 100*time.Millisecond)

	if err == nil {
		t.Fatal("Ping() to invalid address = nil, want error")
	}
	if !strings.Contains(err.Error(), "failed to connect") {
		t.Errorf("error = %q, want to contain %q", err.Error(), "failed to connect")
	}
}

func TestClient_Connect_CanceledContext(t *testing.T) {
	client := NewClient("192.0.2.1", 9999, 10*1024*1024)

	// Create an already-canceled context
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := client.Connect(ctx)
	if err == nil {
		t.Fatal("Connect() with canceled context = nil, want error")
	}
	// The error should indicate the context was canceled
	if !strings.Contains(err.Error(), "canceled") && !strings.Contains(err.Error(), "canceled") {
		t.Errorf("error = %q, want to contain 'canceled'", err.Error())
	}
}

func TestClient_Connect_ContextTimeout(t *testing.T) {
	client := NewClient("192.0.2.1", 9999, 10*1024*1024)

	// Create a context with a very short timeout
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
	defer cancel()

	// Small sleep to ensure the context times out
	time.Sleep(5 * time.Millisecond)

	err := client.Connect(ctx)
	if err == nil {
		t.Fatal("Connect() with expired context = nil, want error")
	}
	// The error should indicate timeout or deadline exceeded
	if !strings.Contains(err.Error(), "deadline") && !strings.Contains(err.Error(), "timeout") && !strings.Contains(err.Error(), "canceled") {
		t.Errorf("error = %q, want to contain 'deadline', 'timeout', or 'canceled'", err.Error())
	}
}

func TestClient_RunVISynchronous_CanceledContext(t *testing.T) {
	client := NewClient("localhost", 2552, 10*1024*1024)

	// Create an already-canceled context
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := client.RunVISynchronous(ctx, "test.vi", nil, 0, false, nil, -1)
	if err == nil {
		t.Fatal("RunVISynchronous() with canceled context = nil, want error")
	}
	// Should fail with "not connected" since we check that first,
	// but the context cancellation check happens after that
	if !strings.Contains(err.Error(), "not connected") && !strings.Contains(err.Error(), "canceled") {
		t.Errorf("error = %q, want to contain 'not connected' or 'canceled'", err.Error())
	}
}
