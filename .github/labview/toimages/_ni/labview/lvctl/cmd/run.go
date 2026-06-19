package cmd

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ni/testhub/src/labview/lvctl/viserver"
)

// RunVICmd runs an arbitrary VI via VI Server, setting controls and reading indicators.
type RunVICmd struct {
	VI         string        `arg:"" help:"Path to the VI to run"`
	Set        []string      `short:"s" help:"Set a control value (name=value), can be repeated" placeholder:"name=value"`
	Get        []string      `short:"g" help:"Indicator names to read after execution, can be repeated" placeholder:"name"`
	SearchDirs []string      `help:"Additional VI search directories" placeholder:"dir"`
	Timeout    time.Duration `help:"Execution timeout" default:"2m"`
}

func (c *RunVICmd) Run(globals *Globals) error {
	absVI, err := filepath.Abs(c.VI)
	if err != nil {
		return fmt.Errorf("failed to resolve path: %w", err)
	}

	controls := make(map[string]any)
	for _, kv := range c.Set {
		parts := strings.SplitN(kv, "=", 2)
		if len(parts) != 2 {
			return fmt.Errorf("invalid control flag %q, expected name=value", kv)
		}
		controls[parts[0]] = parts[1]
	}

	slog.Info("Connecting to LabVIEW via VI Server (COM)...")
	session, err := viserver.Connect()
	if err != nil {
		return err
	}
	defer session.Close()

	slog.Info("Running VI", "path", absVI, "controls", len(controls), "indicators", len(c.Get))
	indicators, err := session.RunVI(c.Timeout, absVI, controls, c.Get, c.SearchDirs...)
	if err != nil {
		return err
	}

	if len(indicators) == 0 {
		return nil
	}

	// If only one indicator, print its value directly.
	if len(indicators) == 1 {
		for _, v := range indicators {
			fmt.Fprintln(os.Stdout, v)
			return nil
		}
	}

	// Multiple indicators: print as JSON.
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(indicators)
}
