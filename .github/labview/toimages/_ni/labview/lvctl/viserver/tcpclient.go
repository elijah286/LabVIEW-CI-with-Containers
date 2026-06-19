package viserver

// TCP client for LabVIEW VI Server protocol.
//
// Implements the binary protocol spoken on port 3363, reverse-engineered from
// the LabVIEW source (TCPServerPrivate.h, tcpserver.cpp, TCPServerPacket.cpp).

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

// tcpConn wraps a TCP connection to a LabVIEW VI Server.
type tcpConn struct {
	conn    net.Conn
	mu      sync.Mutex // serializes request/response pairs
	nextID  atomic.Uint32
	version uint32 // negotiated protocol version
}

// dialTCP connects to a LabVIEW VI Server at the given address and performs the
// protocol handshake. addr should be "host:port", e.g. "127.0.0.1:3363".
func dialTCP(addr string) (*tcpConn, error) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", addr, err)
	}

	tc := &tcpConn{conn: conn}
	tc.nextID.Store(1)

	if err := tc.handshake(); err != nil {
		conn.Close()
		return nil, err
	}
	return tc, nil
}

// handshake sends kTSClientSaysHeaveno and reads kTSServerSaysHeaveno.
func (tc *tcpConn) handshake() error {
	// Build body to match LabVIEW's CliSendGreeting: max protocol/LV version
	// followed by an LStrHandle credentials payload. We send an empty LStr.
	var body bytes.Buffer
	binary.Write(&body, be, protoVersionMax)
	binary.Write(&body, be, int32(0))

	// Header: uniqueID carries our minimum version (the server reads it as
	// clientMinProtocolVersion).
	hdr := tsHeader{
		Error:     0,
		MessageID: msgClientHello,
		UniqueID:  uint32(protoVersionGreetingMin),
		BodyLen:   int32(body.Len()),
	}

	if err := tc.writeMessage(&hdr, body.Bytes()); err != nil {
		return fmt.Errorf("handshake send: %w", err)
	}

	resp, respBody, err := tc.readMessage()
	if err != nil {
		return fmt.Errorf("handshake recv: %w", err)
	}
	if resp.MessageID != msgServerHello {
		return fmt.Errorf("expected ServerHello (10), got %d", resp.MessageID)
	}
	if resp.Error != 0 {
		return fmt.Errorf("server rejected connection: error %d", resp.Error)
	}

	tc.version = resp.UniqueID
	slog.Debug("VI Server TCP handshake complete",
		"negotiatedVersion", fmt.Sprintf("0x%08X", tc.version),
		"bodyLen", len(respBody))
	return nil
}

func (tc *tcpConn) close() error {
	// Send goodbye.
	hdr := tsHeader{
		Error:     0,
		MessageID: msgClientBye,
		UniqueID:  tc.nextID.Add(1),
		BodyLen:   0,
	}
	// Best-effort; ignore errors on close.
	_ = tc.writeMessage(&hdr, nil)
	return tc.conn.Close()
}

// roundTrip sends a request and reads the response. Caller must hold tc.mu.
func (tc *tcpConn) roundTrip(msgID tsMessage, body []byte) (*tsHeader, []byte, error) {
	uid := tc.nextID.Add(1)
	hdr := tsHeader{
		Error:     0,
		MessageID: msgID,
		UniqueID:  uid,
		BodyLen:   int32(len(body)),
	}
	if err := tc.writeMessage(&hdr, body); err != nil {
		return nil, nil, err
	}
	return tc.readMessage()
}

func (tc *tcpConn) writeMessage(hdr *tsHeader, body []byte) error {
	var buf bytes.Buffer
	if err := hdr.writeTo(&buf); err != nil {
		return err
	}
	if len(body) > 0 {
		buf.Write(body)
	}
	_, err := tc.conn.Write(buf.Bytes())
	return err
}

func (tc *tcpConn) readMessage() (*tsHeader, []byte, error) {
	hdr, err := readHeader(tc.conn)
	if err != nil {
		return nil, nil, err
	}
	var body []byte
	if hdr.BodyLen > 0 {
		body = make([]byte, hdr.BodyLen)
		if _, err := io.ReadFull(tc.conn, body); err != nil {
			return nil, nil, fmt.Errorf("read body (%d bytes): %w", hdr.BodyLen, err)
		}
	}
	return hdr, body, nil
}

// ---------- VI Server operations ----------

// openVIRef sends kTSGetVIRefSend and returns the server-side VI reference.
func (tc *tcpConn) openVIRef(viPath string) (uint32, error) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	var body bytes.Buffer
	flatPath, err := flattenVIPath(viPath)
	if err != nil {
		return 0, fmt.Errorf("openVIRef: flatten path: %w", err)
	}

	// appRef (if protocol >= kTSProtocolPassAppRefForOpenVIRef).
	if tc.version >= protoVersionAppRef {
		binary.Write(&body, be, uint32(0)) // 0 = default application
	}

	// viRefFlags (uint32).
	binary.Write(&body, be, uint32(0))

	// Path: flattened LabVIEW Path value, not a raw string.
	binary.Write(&body, be, int32(len(flatPath)))
	body.Write(flatPath)
	// Pad to 2-byte boundary.
	if len(flatPath)%2 != 0 {
		body.WriteByte(0)
	}

	// Type descriptor: 0 means no strict type.
	binary.Write(&body, be, int32(0))

	// Password: empty (4 bytes of zero = empty LStr).
	binary.Write(&body, be, int32(0))

	resp, respBody, err := tc.roundTrip(msgGetVIRefSend, body.Bytes())
	if err != nil {
		return 0, fmt.Errorf("openVIRef: %w", err)
	}
	if resp.Error != 0 {
		return 0, serverErrorf("openVIRef", resp.Error, respBody)
	}
	if len(respBody) < 4 {
		return 0, fmt.Errorf("openVIRef: response too short (%d bytes)", len(respBody))
	}

	viRef := be.Uint32(respBody[0:4])
	slog.Debug("Opened VI reference", "viPath", viPath, "ref", viRef)
	return viRef, nil
}

// releaseRef sends kTSReleaseRef for a VI reference.
func (tc *tcpConn) releaseRef(viRef uint32) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	var body bytes.Buffer
	binary.Write(&body, be, viRef)

	uid := tc.nextID.Add(1)
	hdr := tsHeader{
		Error:     0,
		MessageID: msgReleaseRef,
		UniqueID:  uid,
		BodyLen:   int32(body.Len()),
	}
	if err := tc.writeMessage(&hdr, body.Bytes()); err != nil {
		slog.Debug("releaseRef send failed", "viRef", viRef, "err", err)
		return
	}

	if err := tc.conn.SetReadDeadline(time.Now().Add(1 * time.Second)); err != nil {
		slog.Debug("releaseRef deadline setup failed", "viRef", viRef, "err", err)
		return
	}
	defer tc.conn.SetReadDeadline(time.Time{})

	resp, respBody, err := tc.readMessage()
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			slog.Debug("releaseRef response timed out", "viRef", viRef)
			return
		}
		slog.Debug("releaseRef recv failed", "viRef", viRef, "err", err)
		return
	}
	if resp.Error != 0 {
		slog.Debug("releaseRef server error", "viRef", viRef, "err", serverErrorf("releaseRef", resp.Error, respBody))
	}
}

// callVI sends kTSCallSend to run a VI. controls are set as input parameters
// and indicatorNames are read back as outputs.
//
// The protocol-level Call message works with positional parameters by connector
// pane index, not by name. For simplicity this implementation uses SetControlValue /
// GetControlValue via property messages (which do work by name) before and after
// calling Run.
func (tc *tcpConn) callVI(viRef uint32) error {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	var body bytes.Buffer
	binary.Write(&body, be, int32(viRef))
	// numParams = 0 (we set controls via properties).
	// The body is just the viRef when there are no connector-pane params.

	resp, _, err := tc.roundTrip(msgCallSend, body.Bytes())
	if err != nil {
		return fmt.Errorf("callVI: %w", err)
	}
	if resp.Error != 0 {
		return serverErrorf("callVI", resp.Error, nil)
	}
	return nil
}

// getVIProperty reads a property from a VI by its property ID.
func (tc *tcpConn) getVIProperty(viRef uint32, propID int32, td ...[]byte) ([]byte, error) {
	p := propertyParam{selector: propID, isGet: true}
	if len(td) > 0 {
		p.td = td[0]
	}
	return tc.propertyVector(msgVIAttrSend, viRef, lvClassVI, p)
}

// setVIProperty writes a property value on a VI.
func (tc *tcpConn) setVIProperty(viRef uint32, propID int32, td []byte, data []byte) error {
	_, err := tc.propertyVector(msgVIAttrSend, viRef, lvClassVI, propertyParam{selector: propID, td: td, data: data})
	return err
}

// getAppProperty reads a property from the Application object.
func (tc *tcpConn) getAppProperty(propID int32) ([]byte, error) {
	return tc.propertyVector(msgAppAttrSend, 0, lvClassApp, propertyParam{selector: propID, isGet: true})
}

// getAppPropertyWithTD reads a property from the Application object, sending
// the specified TD so the server allocates data and actually executes the GET.
// Without a TD (paramSize=0), the server skips properties with null data.
func (tc *tcpConn) getAppPropertyWithTD(propID int32, td []byte) ([]byte, error) {
	return tc.propertyVector(msgAppAttrSend, 0, lvClassApp, propertyParam{selector: propID, isGet: true, td: td})
}

// setAppProperty writes a property on the Application object.
func (tc *tcpConn) setAppProperty(propID int32, td []byte, data []byte) error {
	_, err := tc.propertyVector(msgAppAttrSend, 0, lvClassApp, propertyParam{selector: propID, td: td, data: data})
	return err
}

type propertyParam struct {
	selector int32
	isGet    bool
	td       []byte
	data     []byte
}

type methodParam struct {
	isGet bool
	td    []byte
	data  []byte
}

func encodeParamBytes(isGet bool, td []byte, data []byte) []byte {
	if len(td) == 0 && len(data) == 0 {
		return nil
	}

	var buf bytes.Buffer
	binary.Write(&buf, be, int32(len(td)))
	buf.Write(td)
	buf.Write(data)
	if buf.Len()%2 != 0 {
		buf.WriteByte(0)
	}
	return buf.Bytes()
}

func includeFlags(version uint32, msgID tsMessage) bool {
	return msgID == msgObjAttrSend || msgID == msgObjAttrReturn || msgID == msgObjMethodSend || msgID == msgObjMethodReturn || msgID == msgObjMethodSend+2 || msgID == msgObjMethodReturn+2 || version >= protoVersionFlatTDR
}

func includeRFlags(msgID tsMessage) bool {
	return msgID == msgObjAttrSend || msgID == msgObjMethodSend || msgID == msgObjMethodSend+2
}

func (tc *tcpConn) propertyVector(msgID tsMessage, ref uint32, classID int32, param propertyParam) ([]byte, error) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	var body bytes.Buffer
	if msgID != msgAppAttrSend || tc.version >= protoVersionFlatTDR {
		binary.Write(&body, be, ref)
		if msgID != msgAppAttrSend && tc.version >= protoVersionFlatTDR {
			binary.Write(&body, be, classID)
		}
	}

	binary.Write(&body, be, int32(1))
	if includeFlags(tc.version, msgID) {
		flags := uint32(0)
		if param.isGet {
			flags = paramFlagGet
		}
		binary.Write(&body, be, flags)
	} else if param.isGet {
		binary.Write(&body, be, uint32(1))
	} else {
		binary.Write(&body, be, uint32(0))
	}
	if includeRFlags(msgID) {
		binary.Write(&body, be, uint64(0))
	}
	binary.Write(&body, be, param.selector)

	paramBytes := encodeParamBytes(param.isGet, param.td, param.data)
	binary.Write(&body, be, int32(len(paramBytes)))
	body.Write(paramBytes)
	if tc.version >= protoVersionMin {
		binary.Write(&body, be, uint32(0))
	}

	resp, respBody, err := tc.roundTrip(msgID, body.Bytes())
	if err != nil {
		return nil, err
	}
	if resp.Error != 0 {
		return nil, serverErrorf(fmt.Sprintf("propertyVector(%d)", param.selector), resp.Error, respBody)
	}
	return respBody, nil
}

func (tc *tcpConn) methodVector(msgID tsMessage, ref uint32, classID int32, methodID int32, params ...methodParam) ([]byte, error) {
	tc.mu.Lock()
	defer tc.mu.Unlock()

	var body bytes.Buffer
	binary.Write(&body, be, ref)
	if tc.version >= protoVersionFlatTDR {
		binary.Write(&body, be, classID)
	}
	binary.Write(&body, be, methodID)
	if includeRFlags(msgID) {
		binary.Write(&body, be, uint64(0))
	}
	binary.Write(&body, be, int32(len(params)))
	for _, param := range params {
		flags := uint32(0)
		if param.isGet {
			flags = paramFlagGet
		}
		binary.Write(&body, be, flags)
		if includeRFlags(msgID) {
			binary.Write(&body, be, uint64(0))
		}

		paramBytes := encodeParamBytes(param.isGet, param.td, param.data)
		binary.Write(&body, be, int32(len(paramBytes)))
		body.Write(paramBytes)
	}

	resp, respBody, err := tc.roundTrip(msgID, body.Bytes())
	if err != nil {
		return nil, err
	}
	if resp.Error != 0 {
		return nil, serverErrorf(fmt.Sprintf("methodVector(%d)", methodID), resp.Error, respBody)
	}
	return respBody, nil
}

func serverErrorf(prefix string, code int32, body []byte) error {
	if detail := strings.TrimSpace(string(bytes.Trim(body, "\x00"))); detail != "" && utf8.ValidString(detail) {
		return fmt.Errorf("%s: server error %d: %s", prefix, code, detail)
	}
	return fmt.Errorf("%s: server error %d", prefix, code)
}
