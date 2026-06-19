package labview

import (
	"errors"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestBsonDToMap(t *testing.T) {
	input := bson.D{
		{Key: "status", Value: true},
		{Key: "code", Value: int32(1059)},
		{Key: "source", Value: "test.vi"},
	}

	result := BsonDToMap(input)

	if len(result) != 3 {
		t.Errorf("map length = %d, want 3", len(result))
	}
	if result["status"] != true {
		t.Errorf("result[\"status\"] = %v, want true", result["status"])
	}
	if result["code"] != int32(1059) {
		t.Errorf("result[\"code\"] = %v, want 1059", result["code"])
	}
	if result["source"] != "test.vi" {
		t.Errorf("result[\"source\"] = %q, want \"test.vi\"", result["source"])
	}
}

func TestCheckErrorOut_NoError(t *testing.T) {
	indicators := map[string]any{
		"Error Out": bson.D{
			{Key: "status", Value: false},
			{Key: "code", Value: int32(0)},
			{Key: "source", Value: ""},
		},
	}

	err := CheckErrorOut(indicators)
	if err != nil {
		t.Errorf("CheckErrorOut() = %v, want nil", err)
	}
}

func TestCheckErrorOut_NoErrorOutIndicator(t *testing.T) {
	indicators := map[string]any{
		"SomeOtherIndicator": "value",
	}

	err := CheckErrorOut(indicators)
	if err != nil {
		t.Errorf("CheckErrorOut() = %v, want nil", err)
	}
}

func TestCheckErrorOut_CaseInsensitive(t *testing.T) {
	// LabVIEW defaults to "error out" (lowercase); verify both casings work.
	for _, key := range []string{"Error Out", "error out", "ERROR OUT", "Error out"} {
		indicators := map[string]any{
			key: bson.D{
				{Key: "status", Value: true},
				{Key: "code", Value: int32(9999)},
				{Key: "source", Value: "SomeVI.vi"},
			},
		}

		err := CheckErrorOut(indicators)
		if err == nil {
			t.Errorf("CheckErrorOut() with key %q = nil, want error", key)
		}
	}
}

func TestCheckErrorOut_SimilarButNotErrorOut(t *testing.T) {
	// Ensure keys that merely resemble "error out" are not matched.
	// The function uses EqualFold, so only the exact phrase (any casing) should match.
	for _, key := range []string{"error_out", "ErrorOut", "error out!", "error", "out", "error  out", " error out"} {
		indicators := map[string]any{
			key: bson.D{
				{Key: "status", Value: true},
				{Key: "code", Value: int32(9999)},
				{Key: "source", Value: "SomeVI.vi"},
			},
		}

		err := CheckErrorOut(indicators)
		if err != nil {
			t.Errorf("CheckErrorOut() with key %q = %v, want nil (key should not be treated as error out)", key, err)
		}
	}
}

func TestCheckErrorOut_LabVIEWError(t *testing.T) {
	indicators := map[string]any{
		"Error Out": bson.D{
			{Key: "status", Value: true},
			{Key: "code", Value: int32(9999)},
			{Key: "source", Value: "SomeVI.vi"},
		},
	}

	err := CheckErrorOut(indicators)
	if err == nil {
		t.Fatal("CheckErrorOut() = nil, want error")
	}

	var labVIEWError *LabVIEWError
	if !errors.As(err, &labVIEWError) {
		t.Fatalf("expected *LabVIEWError, got %T", err)
	}

	if labVIEWError.Code != 9999 {
		t.Errorf("Code = %d, want 9999", labVIEWError.Code)
	}
	if labVIEWError.Source != "SomeVI.vi" {
		t.Errorf("Source = %q, want \"SomeVI.vi\"", labVIEWError.Source)
	}
}

func TestCheckErrorOut_LabVIEWInputError_InvalidXML(t *testing.T) {
	indicators := map[string]any{
		"Error Out": bson.D{
			{Key: "status", Value: true},
			{Key: "code", Value: int32(-2628)},
			{Key: "source", Value: "Parser.vi"},
		},
	}

	err := CheckErrorOut(indicators)
	if err == nil {
		t.Fatal("CheckErrorOut() = nil, want error")
	}

	var labVIEWInputError *LabVIEWInputError
	if !errors.As(err, &labVIEWInputError) {
		t.Fatalf("expected *LabVIEWInputError for error -2628, got %T", err)
	}

	if labVIEWInputError.Code != -2628 {
		t.Errorf("Code = %d, want -2628", labVIEWInputError.Code)
	}
}

func TestCheckErrorOut_LabVIEWInputError_InvalidVIFile(t *testing.T) {
	indicators := map[string]any{
		"Error Out": bson.D{
			{Key: "status", Value: true},
			{Key: "code", Value: int32(1059)},
			{Key: "source", Value: "Loader.vi"},
		},
	}

	err := CheckErrorOut(indicators)
	if err == nil {
		t.Fatal("CheckErrorOut() = nil, want error")
	}

	var labVIEWInputError *LabVIEWInputError
	if !errors.As(err, &labVIEWInputError) {
		t.Fatalf("expected *LabVIEWInputError for error 1059, got %T", err)
	}

	if labVIEWInputError.Code != 1059 {
		t.Errorf("Code = %d, want 1059", labVIEWInputError.Code)
	}
}

func TestCheckErrorOut_InvalidType(t *testing.T) {
	indicators := map[string]any{
		"Error Out": "not a bson.D",
	}

	err := CheckErrorOut(indicators)
	if err == nil {
		t.Fatal("CheckErrorOut() = nil, want error")
	}

	expectedSubstring := "unexpected type"
	if !strings.Contains(err.Error(), expectedSubstring) {
		t.Errorf("error = %q, want to contain %q", err.Error(), expectedSubstring)
	}
}

func TestCheckErrorOut_MalformedData(t *testing.T) {
	tests := []struct {
		name            string
		indicators      map[string]any
		expectedErrText string
	}{
		{
			name: "missing status",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "code", Value: int32(0)},
					{Key: "source", Value: ""},
				},
			},
			expectedErrText: "missing status",
		},
		{
			name: "missing code",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "status", Value: true},
					{Key: "source", Value: "test.vi"},
				},
			},
			expectedErrText: "missing code",
		},
		{
			name: "missing source",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "status", Value: true},
					{Key: "code", Value: int32(1)},
				},
			},
			expectedErrText: "missing source",
		},
		{
			name: "invalid status type",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "status", Value: "not a bool"},
					{Key: "code", Value: int32(0)},
					{Key: "source", Value: ""},
				},
			},
			expectedErrText: "status has unexpected type",
		},
		{
			name: "invalid code type",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "status", Value: true},
					{Key: "code", Value: "not an int32"},
					{Key: "source", Value: "test.vi"},
				},
			},
			expectedErrText: "code has unexpected type",
		},
		{
			name: "invalid source type",
			indicators: map[string]any{
				"Error Out": bson.D{
					{Key: "status", Value: true},
					{Key: "code", Value: int32(1)},
					{Key: "source", Value: 12345},
				},
			},
			expectedErrText: "source has unexpected type",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := CheckErrorOut(tt.indicators)
			if err == nil {
				t.Fatalf("CheckErrorOut() = nil, want error for %s", tt.name)
			}
			if !strings.Contains(err.Error(), tt.expectedErrText) {
				t.Errorf("error = %q, want to contain %q", err.Error(), tt.expectedErrText)
			}
		})
	}
}
