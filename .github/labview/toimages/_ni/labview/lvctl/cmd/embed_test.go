package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ni/testhub/src/labview/lvctl/vis"
)

func TestEmbeddedVIs_NonEmpty(t *testing.T) {
	if len(vis.VIToXML) == 0 {
		t.Fatal("embedded VI to XML VI is empty")
	}
	if len(vis.XMLToVI) == 0 {
		t.Fatal("embedded XML to VI VI is empty")
	}
	t.Logf("VI to XML: %d bytes, XML to VI: %d bytes",
		len(vis.VIToXML), len(vis.XMLToVI))
}

func TestEmbeddedVIs_ExtractGeneratorVIs(t *testing.T) {
	dir := t.TempDir()

	viToXML, xmlToVI, err := vis.ExtractGeneratorVIs(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(viToXML); err != nil {
		t.Fatalf("VI to XML not found: %v", err)
	}
	if _, err := os.Stat(xmlToVI); err != nil {
		t.Fatalf("XML to VI not found: %v", err)
	}
	// Verify LV AI Core was extracted alongside
	lvAICore := filepath.Join(dir, "LV AI Core", "XML generator.vi")
	if _, err := os.Stat(lvAICore); err != nil {
		t.Fatalf("LV AI Core dependency not extracted: %v", err)
	}
	t.Logf("Generator VIs and LV AI Core extracted to %s", dir)
}

func TestEmbeddedListener_Extract(t *testing.T) {
	dir := t.TempDir()

	launcher, err := vis.ExtractListener(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(launcher); err != nil {
		t.Fatalf("launcher not found: %v", err)
	}
	t.Logf("Extracted launcher: %s", launcher)
}

func TestEmbeddedLabVIEWIni(t *testing.T) {
	dir := t.TempDir()

	path, err := vis.ExtractLabVIEWIni(dir)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) == 0 {
		t.Fatal("LabVIEW.ini is empty")
	}
	if !contains(string(data), "AllowMultipleInstances") {
		t.Error("LabVIEW.ini missing AllowMultipleInstances setting")
	}
}

func TestToImagesAssets_Present(t *testing.T) {
	if _, err := vis.EmbeddedToImagesHash(); err != nil {
		t.Fatalf("embedded toimages assets unavailable: %v", err)
	}

	t.Setenv("LVCTL_CACHE_DIR", t.TempDir())

	entryVIPath, err := defaultGetVIInfoVIPath()
	if err != nil {
		t.Fatalf("failed to extract toimages assets: %v", err)
	}

	baseDir := filepath.Dir(entryVIPath)
	paths := []string{
		entryVIPath,
		filepath.Join(baseDir, "Combine Frame Data.vi"),
		filepath.Join(baseDir, "Compress Images.vi"),
	}
	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("required toimages asset missing at %s: %v", path, err)
		}
	}
}

// TestToXML_XPlusY verifies the real X Plus Y.vi testdata can be converted
// to XML via LabVIEW's VI Server (COM). Skips if LabVIEW is not available.
func TestToXML_XPlusY(t *testing.T) {
	viFile := filepath.Join("testdata", "X Plus Y.vi")
	if _, err := os.Stat(viFile); err != nil {
		t.Skipf("testdata not available: %v", err)
	}

	cmd := &ToXMLCmd{
		Path:        viFile,
		MaxFileSize: 10,
		Timeout:     1 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err != nil {
		// COM connection to LabVIEW may fail in CI or when LabVIEW isn't installed
		if contains(err.Error(), "LabVIEW") || contains(err.Error(), "COM") {
			t.Skipf("LabVIEW not available: %v", err)
		}
		t.Fatalf("unexpected error: %v", err)
	}
}

// TestFromXML_XPlusY verifies the real X Plus Y.vi.xml testdata can be
// converted back to a VI via LabVIEW's VI Server (COM). Skips if LabVIEW
// is not available.
func TestFromXML_XPlusY(t *testing.T) {
	xmlFile := filepath.Join("testdata", "X Plus Y.vi.xml")
	if _, err := os.Stat(xmlFile); err != nil {
		t.Skipf("testdata not available: %v", err)
	}

	dir := t.TempDir()
	cmd := &FromXMLCmd{
		Path:        xmlFile,
		Output:      filepath.Join(dir, "X Plus Y.vi"),
		MaxFileSize: 10,
		Timeout:     1 * time.Second,
	}
	globals := &Globals{}

	err := cmd.Run(globals)
	if err != nil {
		if contains(err.Error(), "LabVIEW") || contains(err.Error(), "COM") {
			t.Skipf("LabVIEW not available: %v", err)
		}
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify output file was created
	if _, err := os.Stat(filepath.Join(dir, "X Plus Y.vi")); err != nil {
		t.Fatalf("output VI not created: %v", err)
	}
}
