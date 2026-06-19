package viserver

import (
	"bytes"
	"testing"
)

func TestVIMethodRunInstrumentSpecUsesTwoInputBooleans(t *testing.T) {
	falseData, err := flattenData(false)
	if err != nil {
		t.Fatalf("flattenData(false) error = %v", err)
	}

	params, err := viMethodRunInstrumentSpec.buildParams(
		viMethodArg{data: falseData},
		viMethodArg{data: falseData},
	)
	if err != nil {
		t.Fatalf("buildParams() error = %v", err)
	}
	if len(params) != 2 {
		t.Fatalf("len(params) = %d, want 2", len(params))
	}
	for i, param := range params {
		if param.isGet {
			t.Fatalf("params[%d].isGet = true, want false", i)
		}
		if !bytes.Equal(param.td, makeTDSimple(tcBool)) {
			t.Fatalf("params[%d].td = %v, want bool TD", i, param.td)
		}
		if !bytes.Equal(param.data, falseData) {
			t.Fatalf("params[%d].data = %v, want %v", i, param.data, falseData)
		}
	}
}

func TestVIMethodSetCtrlValVariantSpecUsesLeadingPlaceholderOutput(t *testing.T) {
	nameData, err := flattenData("VI Path in")
	if err != nil {
		t.Fatalf("flattenData(name) error = %v", err)
	}

	params, err := viMethodSetCtrlValVariantSpec.buildParams(
		viMethodArg{},
		viMethodArg{data: nameData},
		viMethodArg{data: []byte{1, 2, 3}},
	)
	if err != nil {
		t.Fatalf("buildParams() error = %v", err)
	}
	if len(params) != 3 {
		t.Fatalf("len(params) = %d, want 3", len(params))
	}
	if !params[0].isGet {
		t.Fatalf("params[0].isGet = false, want true")
	}
	if !bytes.Equal(params[1].td, makeTDString()) {
		t.Fatalf("params[1].td = %v, want string TD", params[1].td)
	}
	if !bytes.Equal(params[2].td, makeTDVariant()) {
		t.Fatalf("params[2].td = %v, want variant TD", params[2].td)
	}
}

func TestVIMethodGetCtrlValVariantSpecUsesOutputThenInputOrder(t *testing.T) {
	nameData, err := flattenData("JSON out")
	if err != nil {
		t.Fatalf("flattenData(name) error = %v", err)
	}

	params, err := viMethodGetCtrlValVariantSpec.buildParams(
		viMethodArg{},
		viMethodArg{data: nameData},
	)
	if err != nil {
		t.Fatalf("buildParams() error = %v", err)
	}
	if len(params) != 2 {
		t.Fatalf("len(params) = %d, want 2", len(params))
	}
	if !params[0].isGet {
		t.Fatalf("params[0].isGet = false, want true")
	}
	if params[1].isGet {
		t.Fatalf("params[1].isGet = true, want false")
	}

	resultIndex, err := viMethodGetCtrlValVariantSpec.responseIndex(0)
	if err != nil {
		t.Fatalf("responseIndex() error = %v", err)
	}
	if resultIndex != 0 {
		t.Fatalf("responseIndex(1) = %d, want 0", resultIndex)
	}
}

func TestVIMethodSpecRejectsMissingInputData(t *testing.T) {
	_, err := viMethodSetCtrlValVariantSpec.buildParams(viMethodArg{}, viMethodArg{}, viMethodArg{data: []byte{1}})
	if err == nil {
		t.Fatal("buildParams() error = nil, want error")
	}
}

func TestVIMethodSpecRejectsOutputPayloads(t *testing.T) {
	nameData, err := flattenData("JSON out")
	if err != nil {
		t.Fatalf("flattenData(name) error = %v", err)
	}

	_, err = viMethodGetCtrlValVariantSpec.buildParams(
		viMethodArg{data: []byte{1}},
		viMethodArg{data: nameData},
	)
	if err == nil {
		t.Fatal("buildParams() error = nil, want error")
	}
}
