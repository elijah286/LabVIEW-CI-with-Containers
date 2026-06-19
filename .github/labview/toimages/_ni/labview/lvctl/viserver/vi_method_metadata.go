package viserver

import (
	"fmt"
	"time"
)

type viMethodParamDirection uint8

const (
	viMethodParamIn viMethodParamDirection = iota
	viMethodParamOut
)

type viMethodParamSpec struct {
	name        string
	direction   viMethodParamDirection
	td          []byte
	allowNoData bool
}

type viMethodSpec struct {
	name     string
	methodID int32
	params   []viMethodParamSpec
}

type viMethodArg struct {
	data []byte
}

// These signatures reflect the VI Server TCP method shapes observed from
// LabVIEW itself on macOS:
//   - Run VI: Wait Until Done? (in), Auto Dispose Ref? (in)
//   - Control Value:Set: placeholder return (out void), Control Name (in), Value (in variant)
//   - Control Value:Get: Value (out variant), Control Name (in)
var (
	viMethodRunInstrumentSpec = viMethodSpec{
		name:     "Run VI",
		methodID: viRunMethod,
		params: []viMethodParamSpec{
			{name: "Wait Until Done?", direction: viMethodParamIn, td: makeTDSimple(tcBool)},
			{name: "Auto Dispose Ref?", direction: viMethodParamIn, td: makeTDSimple(tcBool)},
		},
	}
	viMethodAbortSpec = viMethodSpec{
		name:     "Abort VI",
		methodID: viAbortMethod,
	}
	viMethodSetCtrlValVariantSpec = viMethodSpec{
		name:     "Control Value:Set",
		methodID: viSetCtrlVariant,
		params: []viMethodParamSpec{
			{name: "result", direction: viMethodParamOut, td: makeTDSimple(tcVoid)},
			{name: "Control Name", direction: viMethodParamIn, td: makeTDString()},
			{name: "Value", direction: viMethodParamIn, td: makeTDVariant()},
		},
	}
	viMethodGetCtrlValVariantSpec = viMethodSpec{
		name:     "Control Value:Get",
		methodID: viGetCtrlVariant,
		params: []viMethodParamSpec{
			{name: "Value", direction: viMethodParamOut, td: makeTDVariant(), allowNoData: true},
			{name: "Control Name", direction: viMethodParamIn, td: makeTDString()},
		},
	}
)

func (spec viMethodSpec) buildParams(args ...viMethodArg) ([]methodParam, error) {
	if len(args) != len(spec.params) {
		return nil, fmt.Errorf("%s: got %d args, want %d", spec.name, len(args), len(spec.params))
	}

	params := make([]methodParam, len(spec.params))
	for i, paramSpec := range spec.params {
		arg := args[i]
		switch paramSpec.direction {
		case viMethodParamIn:
			if len(arg.data) == 0 && !paramSpec.allowNoData {
				return nil, fmt.Errorf("%s: missing data for input %q", spec.name, paramSpec.name)
			}
			params[i] = methodParam{td: paramSpec.td, data: arg.data}
		case viMethodParamOut:
			if len(arg.data) != 0 {
				return nil, fmt.Errorf("%s: unexpected data for output %q", spec.name, paramSpec.name)
			}
			params[i] = methodParam{isGet: true, td: paramSpec.td}
		default:
			return nil, fmt.Errorf("%s: unsupported direction for %q", spec.name, paramSpec.name)
		}
	}

	return params, nil
}

func (spec viMethodSpec) responseIndex(paramIndex int) (int, error) {
	if paramIndex < 0 || paramIndex >= len(spec.params) {
		return 0, fmt.Errorf("%s: param index %d out of range", spec.name, paramIndex)
	}
	if spec.params[paramIndex].direction != viMethodParamOut {
		return 0, fmt.Errorf("%s: param %q is not an output", spec.name, spec.params[paramIndex].name)
	}

	responseIndex := 0
	for i := 0; i < paramIndex; i++ {
		if spec.params[i].direction == viMethodParamOut {
			responseIndex++
		}
	}
	return responseIndex, nil
}

func (tc *tcpConn) invokeVIMethod(ref uint32, spec viMethodSpec, args ...viMethodArg) ([]byte, error) {
	params, err := spec.buildParams(args...)
	if err != nil {
		return nil, err
	}
	return tc.methodVector(msgVIMethodSend, ref, lvClassVI, spec.methodID, params...)
}

func (tc *tcpConn) invokeVIMethodWithTimeout(ref uint32, spec viMethodSpec, timeout time.Duration, args ...viMethodArg) ([]byte, error) {
	if timeout > 0 {
		if err := tc.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
			return nil, fmt.Errorf("%s: set deadline: %w", spec.name, err)
		}
		defer tc.conn.SetReadDeadline(time.Time{})
	}
	return tc.invokeVIMethod(ref, spec, args...)
}
