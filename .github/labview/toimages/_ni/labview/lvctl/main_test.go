package main

import (
	"testing"

	"github.com/alecthomas/kong"
)

func TestCLI_Parse_ToXML(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := parser.Parse([]string{"toxml", "test.vi"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if ctx.Command() != "toxml <path>" {
		t.Errorf("unexpected command: %s", ctx.Command())
	}
	if cli.ToXML.Path != "test.vi" {
		t.Errorf("expected path test.vi, got %s", cli.ToXML.Path)
	}
	if cli.ToXML.Output != "" {
		t.Errorf("expected empty output, got %s", cli.ToXML.Output)
	}
}

func TestCLI_Parse_ToXML_WithOutput(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	_, err = parser.Parse([]string{"toxml", "input.vi", "output.xml"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if cli.ToXML.Path != "input.vi" {
		t.Errorf("expected path input.vi, got %s", cli.ToXML.Path)
	}
	if cli.ToXML.Output != "output.xml" {
		t.Errorf("expected output output.xml, got %s", cli.ToXML.Output)
	}
}

func TestCLI_Parse_FromXML(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := parser.Parse([]string{"fromxml", "input.xml", "output.vi"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if ctx.Command() != "fromxml <path> <output>" {
		t.Errorf("unexpected command: %s", ctx.Command())
	}
	if cli.FromXML.Path != "input.xml" {
		t.Errorf("expected path input.xml, got %s", cli.FromXML.Path)
	}
	if cli.FromXML.Output != "output.vi" {
		t.Errorf("expected output output.vi, got %s", cli.FromXML.Output)
	}
}

func TestCLI_Parse_ToImages(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	ctx, err := parser.Parse([]string{"toimages", "input.vi"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if ctx.Command() != "toimages <path>" {
		t.Errorf("unexpected command: %s", ctx.Command())
	}
	if len(cli.ToImages.Path) != 1 || cli.ToImages.Path[0] != "input.vi" {
		t.Errorf("expected path [input.vi], got %v", cli.ToImages.Path)
	}
}

func TestCLI_Parse_GlobalFlags(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	_, err = parser.Parse([]string{"-v", "toxml", "input.vi"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if !cli.Verbose {
		t.Error("expected verbose to be true")
	}
}

func TestCLI_Parse_Defaults(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	_, err = parser.Parse([]string{"toimages", "input.vi"})
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if cli.Verbose {
		t.Error("expected verbose to default to false")
	}
}

func TestCLI_Parse_NoCommand(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	_, err = parser.Parse([]string{})
	if err == nil {
		t.Fatal("expected error when no command provided")
	}
}

func TestCLI_Parse_FromXML_MissingOutput(t *testing.T) {
	var cli CLI
	parser, err := kong.New(&cli, kong.Name("lvctl"))
	if err != nil {
		t.Fatal(err)
	}

	_, err = parser.Parse([]string{"fromxml", "input.xml"})
	if err == nil {
		t.Fatal("expected error when fromxml missing required output arg")
	}
}
