package viserver

import (
	"encoding/binary"
	"testing"
)

func TestServerErrorfIncludesServerBody(t *testing.T) {
	err := serverErrorf("methodVector(1003)", 1003, []byte("Method Name: <b>Run VI</b>"))
	if err == nil {
		t.Fatal("serverErrorf() = nil, want error")
	}
	got := err.Error()
	want := "methodVector(1003): server error 1003: Method Name: <b>Run VI</b>"
	if got != want {
		t.Fatalf("serverErrorf() = %q, want %q", got, want)
	}
}

func TestServerErrorfFallsBackWithoutText(t *testing.T) {
	err := serverErrorf("openVIRef", 42, nil)
	if err == nil {
		t.Fatal("serverErrorf() = nil, want error")
	}
	got := err.Error()
	want := "openVIRef: server error 42"
	if got != want {
		t.Fatalf("serverErrorf() = %q, want %q", got, want)
	}
}

func TestEncodeParamBytesKeepsTDWithoutData(t *testing.T) {
	td := makeTDVariant()
	encoded := encodeParamBytes(true, td, nil)
	if len(encoded) == 0 {
		t.Fatal("encodeParamBytes() returned empty bytes, want TD payload")
	}
	if got := int(binary.BigEndian.Uint32(encoded[:4])); got != len(td) {
		t.Fatalf("encoded td len = %d, want %d", got, len(td))
	}
}
