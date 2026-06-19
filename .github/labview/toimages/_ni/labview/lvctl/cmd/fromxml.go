package cmd

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ni/testhub/src/labview/lvctl/vis"
	"github.com/ni/testhub/src/labview/lvctl/viserver"
)

// FromXMLCmd converts XML back to a .vi file via LabVIEW's VI Server (COM).
type FromXMLCmd struct {
	Path   string `arg:"" help:"Path to the XML file to convert"`
	Output string `arg:"" help:"Output .vi file path"`

	XMLToVIVI   string        `help:"Path to the XML-to-VI generator VI (uses embedded VI if omitted)" env:"LVCTL_XML_TO_VI_VI"`
	MaxFileSize int64         `help:"Maximum file size in MiB" default:"10"`
	Timeout     time.Duration `help:"Operation timeout" default:"2m"`
}

func (c *FromXMLCmd) Run(globals *Globals) error {
	slog.Debug("fromxml", "path", c.Path, "output", c.Output)

	// Validate input
	info, err := os.Stat(c.Path)
	if err != nil {
		return fmt.Errorf("cannot access file %s: %w", c.Path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("input path is a directory: %s", c.Path)
	}
	if !strings.HasSuffix(strings.ToLower(c.Path), ".xml") {
		return fmt.Errorf("expected a .xml file, got: %s", c.Path)
	}

	if c.Output == "" {
		return fmt.Errorf("output path is required for XML-to-VI conversion")
	}

	xmlContent, err := os.ReadFile(c.Path)
	if err != nil {
		return fmt.Errorf("failed to read %s: %w", c.Path, err)
	}

	maxBytes := c.MaxFileSize * 1024 * 1024
	if int64(len(xmlContent)) > maxBytes {
		return fmt.Errorf("file size %d bytes exceeds maximum %d MiB", len(xmlContent), c.MaxFileSize)
	}

	// If no generator VI path specified, extract embedded VIs + dependencies.
	if c.XMLToVIVI == "" {
		dir, err := os.MkdirTemp("", "lvctl-vis-*")
		if err != nil {
			return fmt.Errorf("failed to create temp dir for embedded VIs: %w", err)
		}
		defer os.RemoveAll(dir)

		_, xmlToVI, err := vis.ExtractGeneratorVIs(dir)
		if err != nil {
			return err
		}
		c.XMLToVIVI = xmlToVI
		slog.Info("Using embedded generator VI")
	}

	viContent, err := xmlToVI(c.Timeout, c.XMLToVIVI, xmlContent)
	if err != nil {
		return err
	}

	if err := os.WriteFile(c.Output, viContent, 0644); err != nil {
		return fmt.Errorf("failed to write output: %w", err)
	}
	slog.Info("Wrote VI", "path", c.Output)
	return nil
}

func xmlToVI(timeout time.Duration, xmlToVIVI string, xmlContent []byte) ([]byte, error) {
	// Create a temp dir for the output VI
	tempDir, err := os.MkdirTemp("", "lvctl-*")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer os.RemoveAll(tempDir)

	tempVIPath := filepath.Join(tempDir, "output.vi")

	slog.Info("Generator VI", "path", xmlToVIVI)
	slog.Info("Temp output", "path", tempVIPath)
	slog.Info("Connecting to LabVIEW via VI Server (COM)...")

	session, err := viserver.Connect()
	if err != nil {
		return nil, err
	}
	defer session.Close()

	slog.Info("Running XML-to-VI conversion...")

	// Pass the generator VI's directory so LabVIEW can resolve sub-VI dependencies
	_, err = session.RunVI(
		timeout,
		xmlToVIVI,
		map[string]any{
			"XML (UTF-8 encoded)": string(xmlContent),
			"VI Path":             tempVIPath,
		},
		nil,
		filepath.Dir(xmlToVIVI),
	)
	if err != nil {
		return nil, fmt.Errorf("XML-to-VI call failed: %w", err)
	}

	viContent, err := os.ReadFile(tempVIPath)
	if err != nil {
		return nil, fmt.Errorf("output VI file not found (LabVIEW may not have written it): %w", err)
	}

	return viContent, nil
}
