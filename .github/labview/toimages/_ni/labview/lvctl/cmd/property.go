package cmd

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"

	"github.com/ni/testhub/src/labview/lvctl/viserver"
)

// GetPropCmd reads a property from the LabVIEW Application or a VI.
type GetPropCmd struct {
	Property string `arg:"" help:"Property name to read (e.g. Version, AppName)"`
	VI       string `help:"If set, read the property from this VI instead of the Application object" placeholder:"path"`
}

func (c *GetPropCmd) Run(globals *Globals) error {
	slog.Info("Connecting to LabVIEW via VI Server (COM)...")
	session, err := viserver.Connect()
	if err != nil {
		return err
	}
	defer session.Close()

	var val interface{}
	if c.VI != "" {
		vi, err := filepath.Abs(c.VI)
		if err != nil {
			return fmt.Errorf("failed to resolve path: %w", err)
		}
		slog.Info("Getting VI property", "vi", vi, "property", c.Property)
		val, err = session.GetVIProperty(vi, c.Property)
	} else {
		slog.Info("Getting application property", "property", c.Property)
		val, err = session.GetAppProperty(c.Property)
	}
	if err != nil {
		return err
	}

	return printValue(val)
}

// SetPropCmd writes a property on the LabVIEW Application or a VI.
type SetPropCmd struct {
	Property string `arg:"" help:"Property name to set"`
	Value    string `arg:"" help:"Value to set (string; use --int or --bool for typed values)"`
	VI       string `help:"If set, write the property on this VI instead of the Application object" placeholder:"path"`
	Int      bool   `help:"Interpret value as an integer"`
	Bool     bool   `help:"Interpret value as a boolean"`
}

func (c *SetPropCmd) Run(globals *Globals) error {
	slog.Info("Connecting to LabVIEW via VI Server (COM)...")
	session, err := viserver.Connect()
	if err != nil {
		return err
	}
	defer session.Close()

	var typedVal interface{} = c.Value
	if c.Int {
		n, err := strconv.Atoi(c.Value)
		if err != nil {
			return fmt.Errorf("invalid integer %q: %w", c.Value, err)
		}
		typedVal = n
	} else if c.Bool {
		b, err := strconv.ParseBool(c.Value)
		if err != nil {
			return fmt.Errorf("invalid boolean %q: %w", c.Value, err)
		}
		typedVal = b
	}

	if c.VI != "" {
		vi, err := filepath.Abs(c.VI)
		if err != nil {
			return fmt.Errorf("failed to resolve path: %w", err)
		}
		slog.Info("Setting VI property", "vi", vi, "property", c.Property, "value", typedVal)
		return session.SetVIProperty(vi, c.Property, typedVal)
	}
	slog.Info("Setting application property", "property", c.Property, "value", typedVal)
	return session.SetAppProperty(c.Property, typedVal)
}

// CallCmd invokes a method on the LabVIEW Application or a VI.
type CallCmd struct {
	Method string   `arg:"" help:"Method name to call (e.g. GetVIVersion, Quit)"`
	Args   []string `arg:"" optional:"" help:"Arguments to pass to the method"`
	VI     string   `help:"If set, call the method on this VI instead of the Application object" placeholder:"path"`
}

func (c *CallCmd) Run(globals *Globals) error {
	slog.Info("Connecting to LabVIEW via VI Server (COM)...")
	session, err := viserver.Connect()
	if err != nil {
		return err
	}
	defer session.Close()

	// Convert string args to interface{} for the COM call.
	args := make([]interface{}, len(c.Args))
	for i, a := range c.Args {
		args[i] = a
	}

	var val interface{}
	if c.VI != "" {
		vi, err := filepath.Abs(c.VI)
		if err != nil {
			return fmt.Errorf("failed to resolve path: %w", err)
		}
		slog.Info("Calling VI method", "vi", vi, "method", c.Method)
		val, err = session.CallVIMethod(vi, c.Method, args...)
	} else {
		slog.Info("Calling application method", "method", c.Method)
		val, err = session.CallAppMethod(c.Method, args...)
	}
	if err != nil {
		return err
	}
	if val == nil {
		return nil
	}
	return printValue(val)
}

func printValue(val interface{}) error {
	switch v := val.(type) {
	case string:
		fmt.Fprintln(os.Stdout, v)
	case nil:
		// nothing
	default:
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}
	return nil
}
