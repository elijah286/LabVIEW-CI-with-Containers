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

// ToXMLCmd converts a .vi file to XML via LabVIEW's VI Server (COM).
type ToXMLCmd struct {
	Path   string `arg:"" help:"Path to the .vi file to convert"`
	Output string `arg:"" optional:"" help:"Output XML file path (omit to write to stdout)"`

	VIToXMLVI   string        `help:"Path to the VI-to-XML generator VI (uses embedded VI if omitted)" env:"LVCTL_VI_TO_XML_VI"`
	MaxFileSize int64         `help:"Maximum file size in MiB" default:"10"`
	Timeout     time.Duration `help:"Operation timeout" default:"2m"`
}

func (c *ToXMLCmd) Run(globals *Globals) error {
	slog.Debug("toxml", "path", c.Path, "output", c.Output)

	// Validate input
	info, err := os.Stat(c.Path)
	if err != nil {
		return fmt.Errorf("cannot access file %s: %w", c.Path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("input path is a directory: %s", c.Path)
	}
	if !strings.HasSuffix(strings.ToLower(c.Path), ".vi") {
		return fmt.Errorf("expected a .vi file, got: %s", c.Path)
	}

	// Check file size before passing to LabVIEW
	maxBytes := c.MaxFileSize * 1024 * 1024
	if info.Size() > maxBytes {
		return fmt.Errorf("file size %d bytes exceeds maximum %d MiB", info.Size(), c.MaxFileSize)
	}

	// If no generator VI path specified, extract embedded VIs + dependencies.
	if c.VIToXMLVI == "" {
		dir, err := os.MkdirTemp("", "lvctl-vis-*")
		if err != nil {
			return fmt.Errorf("failed to create temp dir for embedded VIs: %w", err)
		}
		defer os.RemoveAll(dir)

		viToXML, _, err := vis.ExtractGeneratorVIs(dir)
		if err != nil {
			return err
		}
		c.VIToXMLVI = viToXML
		slog.Info("Using embedded generator VI")
	}

	xmlContent, err := viToXML(c.Timeout, c.VIToXMLVI, c.Path)
	if err != nil {
		return err
	}

	if c.Output == "" {
		_, err := os.Stdout.Write(xmlContent)
		return err
	}

	if err := os.WriteFile(c.Output, xmlContent, 0644); err != nil {
		return fmt.Errorf("failed to write output: %w", err)
	}
	slog.Info("Wrote XML", "path", c.Output)
	return nil
}

func viToXML(timeout time.Duration, viToXMLVI string, viPath string) ([]byte, error) {
	// Resolve to absolute path since LabVIEW needs a full path
	absVIPath, err := filepath.Abs(viPath)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve absolute path: %w", err)
	}

	slog.Info("Generator VI", "path", viToXMLVI)
	slog.Info("Input VI path", "path", absVIPath)
	slog.Info("Connecting to LabVIEW via VI Server (COM)...")

	session, err := viserver.Connect()
	if err != nil {
		return nil, err
	}
	defer session.Close()

	slog.Info("Running VI-to-XML conversion...")

	// Pass the generator VI's directory so LabVIEW can resolve sub-VI dependencies
	indicators, err := session.RunVI(
		timeout,
		viToXMLVI,
		map[string]any{"VI Path": absVIPath},
		[]string{"XML (UTF-8 encoded)"},
		filepath.Dir(viToXMLVI),
	)
	if err != nil {
		return nil, fmt.Errorf("VI-to-XML call failed: %w", err)
	}

	xmlContent, ok := indicators["XML (UTF-8 encoded)"]
	if !ok {
		return nil, fmt.Errorf("no XML content returned from conversion")
	}
	xmlString, ok := xmlContent.(string)
	if !ok {
		return nil, fmt.Errorf("XML content has unexpected type: %T", xmlContent)
	}
	if xmlString == "" {
		return nil, fmt.Errorf("conversion returned empty XML")
	}

	return []byte(xmlString), nil
}
