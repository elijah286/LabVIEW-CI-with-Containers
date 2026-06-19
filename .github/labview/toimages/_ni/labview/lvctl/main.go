package main

import (
	"fmt"
	"log/slog"
	"os"

	"github.com/alecthomas/kong"
	"github.com/ni/testhub/src/labview/lvctl/cmd"
)

var (
	version = "dev"
	commit  = "none"
)

// CLI defines the top-level command structure for lvctl.
type CLI struct {
	ToXML    cmd.ToXMLCmd    `cmd:"" name:"toxml" help:"Convert a LabVIEW VI file to XML"`
	FromXML  cmd.FromXMLCmd  `cmd:"" name:"fromxml" help:"Convert XML back to a LabVIEW VI file"`
	ToImages cmd.ToImagesCmd `cmd:"" name:"toimages" help:"Convert a LabVIEW VI file to image JSON via Get VI Info.vi"`
	Run      cmd.RunVICmd    `cmd:"" name:"run" help:"Run a VI and read its indicators (generic VI Server call)"`
	Get      cmd.GetPropCmd  `cmd:"" name:"get" help:"Get a LabVIEW application or VI property"`
	Set      cmd.SetPropCmd  `cmd:"" name:"set" help:"Set a LabVIEW application or VI property"`
	Call     cmd.CallCmd     `cmd:"" name:"call" help:"Call a LabVIEW application or VI method"`

	// Global flags
	Version VersionFlag `name:"version" help:"Print version information and exit"`
	Verbose bool        `short:"v" help:"Enable verbose logging"`
}

type VersionFlag bool

func (v VersionFlag) BeforeApply(ctx *kong.Context) error {
	fmt.Printf("lvctl %s (commit %s)\n", version, commit)
	ctx.Kong.Exit(0)
	return nil
}

func main() {
	cli := &CLI{}

	ctx := kong.Parse(cli,
		kong.Name("lvctl"),
		kong.Description("LabVIEW control CLI — convert VIs, manage LabVIEW automation"),
		kong.UsageOnError(),
		kong.ConfigureHelp(kong.HelpOptions{
			Compact: true,
		}),
	)

	// Setup logger
	level := slog.LevelWarn
	if cli.Verbose {
		level = slog.LevelDebug
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)

	err := ctx.Run(&cmd.Globals{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
