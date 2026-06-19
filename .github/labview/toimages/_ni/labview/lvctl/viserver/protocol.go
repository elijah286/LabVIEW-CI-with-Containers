package viserver

import (
	"encoding/binary"
	"fmt"
	"io"
)

// Wire byte order — LabVIEW VI Server TCP protocol is always big-endian.
var be = binary.BigEndian

// Default ports.
const (
	DefaultVIServerPort = 3363
)

// Protocol version constants from TCPServerPrivate.h.
// These use LabVIEW's VERS(major,minor,fix,stage,build) macro.
const (
	// Minimum server protocol the client accepts during ClientHello.
	protoVersionGreetingMin uint32 = 0x00000006 // kTSProtocol6_Old

	// Minimum version we claim to support (LabVIEW 6.0 style).
	protoVersionMin uint32 = 0x06000020 // VERS(6,0,0,kDev,0)

	// Maximum version we advertise. We use 8.5-era to get modern TDR
	// flattening but avoid needing features from very recent versions.
	protoVersionMax uint32 = 0x08508007 // VERS(8,5,0,kBeta,7) — sends 64-bit rflags

	// Threshold for new-style (FlatTDR) type descriptors.
	protoVersionFlatTDR uint32 = 0x08000020 // VERS(8,0,0,kDev,0)

	// Threshold for passing appRef in OpenVIRef.
	protoVersionAppRef uint32 = 0x0900100F // VERS(9,0,1,kDev,15)

	// Threshold for long error strings.
	protoVersionLongErr uint32 = 0x0C0000AB // VERS(12,0,0,kDev,171)
)

// TSMessage — message type identifiers on the wire.
type tsMessage int32

const (
	msgClientHello     tsMessage = 0
	msgAppAttrSend     tsMessage = 1
	msgVIAttrSend      tsMessage = 2
	msgGetVIRefSend    tsMessage = 3
	msgCallSend        tsMessage = 4
	msgAppMethodSend   tsMessage = 5
	msgVIMethodSend    tsMessage = 6
	msgReleaseRef      tsMessage = 7
	msgClientBye       tsMessage = 8
	msgResetDownSend   tsMessage = 9
	msgServerHello     tsMessage = 10
	msgAppAttrReturn   tsMessage = 11
	msgVIAttrReturn    tsMessage = 12
	msgGetVIRefReturn  tsMessage = 13
	msgCallReturn      tsMessage = 14
	msgAppMethodReturn tsMessage = 15
	msgVIMethodReturn  tsMessage = 16
	msgServerBye       tsMessage = 17
	msgErrorStop       tsMessage = 18
	msgResetDownReturn tsMessage = 19
	msgGetObjRefSend   tsMessage = 20
	msgGetObjRefReturn tsMessage = 21
	msgObjAttrSend     tsMessage = 22
	msgObjAttrReturn   tsMessage = 23
	msgObjMethodSend   tsMessage = 24
	msgObjMethodReturn tsMessage = 25
	msgCreateNewVISend tsMessage = 26
	msgTypeCastObjSend tsMessage = 28
	msgPingSend        tsMessage = 30
	msgPingReturn      tsMessage = 31
	msgReleaseObjRef   tsMessage = 32
	msgReleaseLVAppRef tsMessage = 50
)

const (
	lvClassApp int32 = 0x01
	lvClassVI  int32 = 0x02
)

const (
	paramFlagGet uint32 = 1 << 0
)

// tsHeader is the 16-byte message header on the wire.
type tsHeader struct {
	Error     int32
	MessageID tsMessage
	UniqueID  uint32
	BodyLen   int32
}

const headerSize = 16

func (h *tsHeader) writeTo(w io.Writer) error {
	return binary.Write(w, be, h)
}

func readHeader(r io.Reader) (*tsHeader, error) {
	var h tsHeader
	if err := binary.Read(r, be, &h); err != nil {
		return nil, fmt.Errorf("read header: %w", err)
	}
	return &h, nil
}

// Property access flags.
const (
	propFlagGet uint32 = 0x0001
	propFlagSet uint32 = 0x0000
)
