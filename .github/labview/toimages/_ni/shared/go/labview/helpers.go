package labview

import (
	"fmt"
	"strings"

	"go.mongodb.org/mongo-driver/v2/bson"
)

// BsonDToMap converts a bson.D to a map[string]any.
func BsonDToMap(d bson.D) map[string]any {
	m := make(map[string]any, len(d))
	for _, elem := range d {
		m[elem.Key] = elem.Value
	}
	return m
}

// CheckErrorOut checks for LabVIEW errors in the indicator values.
// The lookup is case-insensitive to handle both "Error Out" (standard convention)
// and "error out" (LabVIEW default naming) and any other casing variant.
func CheckErrorOut(indicators map[string]any) error {
	for k, v := range indicators {
		if strings.EqualFold(k, "error out") {
			// BSON unmarshaling into any/interface{} always produces bson.D for documents
			errorBsonD, ok := v.(bson.D)
			if !ok {
				return fmt.Errorf("Error Out has unexpected type: %T", v)
			}
			return errorClusterMapToLabVIEWError(BsonDToMap(errorBsonD))
		}
	}
	return nil
}
