// Package labview provides a client for communicating with LabVIEW's automation listener.
package labview

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log/slog"
	"net"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

// Client provides communication with the LabVIEW automation listener over TCP using BSON encoding.
type Client struct {
	address        string
	port           int
	conn           net.Conn
	maxMessageSize int64
}

// LabVIEWError represents an error returned from LabVIEW during VI execution.
type LabVIEWError struct {
	Code   int32
	Source string
}

func (e *LabVIEWError) Error() string {
	return fmt.Sprintf("LabVIEW Error %d: %s", e.Code, e.Source)
}

// LabVIEWInputError represents a client input error (HTTP 400) from LabVIEW.
// This indicates malformed or invalid input data.
type LabVIEWInputError struct {
	LabVIEWError
}

// LabVIEW error codes that indicate client input errors.
const (
	// LabVIEWError_AnErrorOccurredWhileParsingTheDocument indicates malformed/invalid/empty VI XML.
	LabVIEWError_AnErrorOccurredWhileParsingTheDocument = -2628
	// LabVIEWError_UnexpectedFileType indicates invalid VI file format.
	LabVIEWError_UnexpectedFileType = 1059
)

// NewClient creates a new LabVIEW client for the given address and port.
// maxFileSizeBytes sets the maximum expected file size, message size limit will be 2x this value.
func NewClient(address string, port int, maxFileSizeBytes int64) *Client {
	return &Client{
		address:        address,
		port:           port,
		maxMessageSize: maxFileSizeBytes * 2,
	}
}

// Connect establishes a TCP connection to the LabVIEW listener.
// The context controls connection establishment timeout and cancellation.
func (c *Client) Connect(ctx context.Context) error {
	if c == nil {
		return fmt.Errorf("Connect called with nil receiver")
	}
	addr := net.JoinHostPort(c.address, fmt.Sprintf("%d", c.port))

	// Use a dialer with context for cancellation support.
	// Default timeout of 30s if no deadline is set on the context.
	dialer := net.Dialer{Timeout: 30 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to connect to LabVIEW at %s: %w", addr, err)
	}

	// Set TCP keepalive options using cross-platform behavior.
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		if err := configureTCPKeepAlive(tcpConn); err != nil {
			conn.Close()
			return fmt.Errorf("failed to configure keepalive: %w", err)
		}
	}

	c.conn = conn
	return nil
}

// configureTCPKeepAlive applies keepalive settings across platforms.
// Primary behavior mirrors labview_automation intent: enable keepalive with idle=60s and interval=5s.
// If full keepalive tuning is unavailable on a platform/runtime, falls back to enabling keepalive only.
func configureTCPKeepAlive(tcpConn *net.TCPConn) error {
	err := tcpConn.SetKeepAliveConfig(net.KeepAliveConfig{
		Enable:   true,
		Idle:     60 * time.Second,
		Interval: 5 * time.Second,
		Count:    -1,
	})
	if err == nil {
		return nil
	}

	slog.Warn("Failed to apply keepalive idle/interval config, falling back to enable-only keepalive", "error", err)
	return tcpConn.SetKeepAlive(true)
}

// Close closes the connection to the LabVIEW listener.
func (c *Client) Close() error {
	if c == nil {
		return nil
	}
	if c.conn != nil {
		err := c.conn.Close()
		c.conn = nil
		return err
	}
	return nil
}

// RunVISynchronous runs a VI synchronously and returns the indicator values.
// This is the primary method for executing LabVIEW VIs through the automation interface.
// The context controls I/O deadlines; if the context has a deadline, it will be applied
// to the underlying TCP connection for both send and receive operations.
func (c *Client) RunVISynchronous(
	ctx context.Context,
	viPath string,
	controlValues map[string]any,
	runOptions int,
	openFrontPanel bool,
	indicatorNames []string,
	timeout int,
) (map[string]any, error) {
	if c == nil {
		return nil, fmt.Errorf("RunVISynchronous called with nil receiver")
	}
	if c.conn == nil {
		return nil, fmt.Errorf("client not connected")
	}

	// Apply context deadline to the connection if set.
	// This ensures I/O operations respect HTTP request timeouts.
	if deadline, ok := ctx.Deadline(); ok {
		if err := c.conn.SetDeadline(deadline); err != nil {
			return nil, fmt.Errorf("failed to set connection deadline: %w", err)
		}
	}

	// Check for cancellation before starting
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Ensure indicatorNames is an empty slice rather than nil.
	// BSON encodes nil as null (type 0x0A), but LabVIEW expects an array (type 0x04).
	// Passing null causes Error 1448 (bad type cast) in BSON.lvlib:tBSONDocument.lvclass:getString[]Value.vi.
	if indicatorNames == nil {
		indicatorNames = []string{}
	}

	// Build the command message
	msg := map[string]any{
		"command":         "run_vi",
		"vi_path":         viPath,
		"run_options":     runOptions,
		"open_frontpanel": openFrontPanel,
		"control_values":  controlValues,
		"indicator_names": indicatorNames,
		"timeout":         timeout,
	}

	// Send the message
	if err := c.sendMessage(msg); err != nil {
		return nil, fmt.Errorf("failed to send run_vi command: %w", err)
	}

	// Receive the response
	response, err := c.receiveMessage()
	if err != nil {
		return nil, fmt.Errorf("failed to receive response: %w", err)
	}

	// Check for errors in the response
	if err := c.checkForError(response); err != nil {
		return nil, err
	}

	return response, nil
}

// sendMessage encodes and sends a BSON message over the connection.
// The protocol is: 4-byte little-endian size prefix followed by BSON data.
// Note: BSON already includes its own size in the first 4 bytes, so we just send the BSON directly.
func (c *Client) sendMessage(msg map[string]any) error {
	if c == nil {
		return fmt.Errorf("sendMessage called with nil receiver")
	}
	data, err := bson.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal BSON: %w", err)
	}

	// BSON already includes a 4-byte size prefix, so we send it directly
	_, err = c.conn.Write(data)
	if err != nil {
		return fmt.Errorf("failed to write to connection: %w", err)
	}

	return nil
}

// receiveMessage reads a BSON message from the connection.
// The protocol is: 4-byte little-endian size prefix followed by BSON data.
func (c *Client) receiveMessage() (map[string]any, error) {
	if c == nil {
		return nil, fmt.Errorf("receiveMessage called with nil receiver")
	}
	// Read the 4-byte size prefix (part of BSON format)
	sizeBytes := make([]byte, 4)
	if _, err := io.ReadFull(c.conn, sizeBytes); err != nil {
		return nil, fmt.Errorf("failed to read message size: %w", err)
	}

	// The size is stored as int32 little-endian and includes the 4 size bytes
	size := int32(binary.LittleEndian.Uint32(sizeBytes))
	if size <= 4 || int64(size) > c.maxMessageSize {
		return nil, fmt.Errorf("invalid message size: %d (max: %d)", size, c.maxMessageSize)
	}

	// Read the remaining bytes
	data := make([]byte, size)
	copy(data[:4], sizeBytes) // Include the size bytes as part of BSON
	if _, err := io.ReadFull(c.conn, data[4:]); err != nil {
		return nil, fmt.Errorf("failed to read message body: %w", err)
	}

	// Decode the BSON message
	var result map[string]any
	if err := bson.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("failed to unmarshal BSON: %w", err)
	}

	return result, nil
}

// checkForError checks if the response contains an error from LabVIEW.
func (c *Client) checkForError(response map[string]any) error {
	return errorClusterMapToLabVIEWErrorCustom(response, "RunVIState_Status", "RunVIState_Code", "RunVIState_Source")
}

// errorClusterMapToLabVIEWError extracts error information from a map using the standard LabVIEW
// error cluster keys: "status", "code", "source".
// Returns nil if no error (status key missing or status is false).
// Returns the appropriate LabVIEWError or LabVIEWInputError based on the error code.
func errorClusterMapToLabVIEWError(m map[string]any) error {
	return errorClusterMapToLabVIEWErrorCustom(m, "status", "code", "source")
}

// errorClusterMapToLabVIEWErrorCustom extracts error information from a map using the specified key names.
// Returns nil if no error (status is false).
// Returns an error if required fields are missing or have unexpected types.
// Returns the appropriate LabVIEWError or LabVIEWInputError based on the error code.
func errorClusterMapToLabVIEWErrorCustom(m map[string]any, statusKey, codeKey, sourceKey string) error {
	statusAny, ok := m[statusKey]
	if !ok {
		return fmt.Errorf("error cluster missing %s field", statusKey)
	}

	status, ok := statusAny.(bool)
	if !ok {
		return fmt.Errorf("error cluster %s has unexpected type: %T", statusKey, statusAny)
	}

	// No error if status is false
	if !status {
		return nil
	}

	codeAny, ok := m[codeKey]
	if !ok {
		return fmt.Errorf("error cluster missing %s field", codeKey)
	}

	code, ok := codeAny.(int32)
	if !ok {
		return fmt.Errorf("error cluster %s has unexpected type: %T", codeKey, codeAny)
	}

	sourceAny, ok := m[sourceKey]
	if !ok {
		return fmt.Errorf("error cluster missing %s field", sourceKey)
	}

	source, ok := sourceAny.(string)
	if !ok {
		return fmt.Errorf("error cluster %s has unexpected type: %T", sourceKey, sourceAny)
	}

	// Error -2628: An error occurred while parsing the document.
	// - Indicates malformed/invalid/empty VI XML.
	// Error 1059: Unexpected file type.
	// - Indicates invalid VI file format.
	if code == LabVIEWError_AnErrorOccurredWhileParsingTheDocument || code == LabVIEWError_UnexpectedFileType {
		return &LabVIEWInputError{
			LabVIEWError: LabVIEWError{
				Code:   code,
				Source: source,
			},
		}
	}

	return &LabVIEWError{
		Code:   code,
		Source: source,
	}
}

// Ping attempts to connect to the LabVIEW listener to verify it's running.
func Ping(address string, port int, timeout time.Duration) error {
	addr := net.JoinHostPort(address, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return fmt.Errorf("failed to connect to LabVIEW at %s: %w", addr, err)
	}
	conn.Close()
	return nil
}
