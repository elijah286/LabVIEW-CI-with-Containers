// Package vis embeds small LabVIEW assets and resolves larger shared assets from
// the repository so lvctl can run without duplicating the full dependency tree.
package vis

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

//go:embed "VI to XML.vi"
var VIToXML []byte

//go:embed "XML to VI.vi"
var XMLToVI []byte

//go:embed LabVIEW.ini
var LabVIEWIni []byte

//go:embed toimages.zip
var ToImagesZip []byte

func repoRoot() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to resolve working directory: %w", err)
	}

	for dir := wd; ; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir, nil
		}
		if _, err := os.Stat(filepath.Join(dir, "go.work")); err == nil {
			return dir, nil
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}

	return "", fmt.Errorf("failed to locate repository root from %s", wd)
}

// Extract writes a single embedded file to dir and returns the full path.
func Extract(dir string, name string, data []byte) (string, error) {
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0600); err != nil {
		return "", fmt.Errorf("failed to extract embedded VI %s: %w", name, err)
	}
	return path, nil
}

// ExtractGeneratorVIs extracts the generator VIs and their LV AI Core
// dependencies into dir. Returns paths to VI-to-XML and XML-to-VI VIs.
// Everything goes in the same directory tree so LabVIEW can resolve sub-VIs.
func ExtractGeneratorVIs(dir string) (viToXMLPath, xmlToVIPath string, err error) {
	depsPath, err := generatorDependenciesZipPath()
	if err != nil {
		return "", "", err
	}

	depsZip, err := os.ReadFile(depsPath)
	if err != nil {
		return "", "", fmt.Errorf("failed to read LV AI Core archive %s: %w", depsPath, err)
	}

	if err := extractZip(depsZip, dir); err != nil {
		return "", "", fmt.Errorf("failed to extract LV AI Core: %w", err)
	}

	// Extract the generator VIs alongside
	viToXMLPath, err = Extract(dir, "VI to XML.vi", VIToXML)
	if err != nil {
		return "", "", err
	}
	xmlToVIPath, err = Extract(dir, "XML to VI.vi", XMLToVI)
	if err != nil {
		return "", "", err
	}
	return viToXMLPath, xmlToVIPath, nil
}

// ExtractListener unzips the embedded lv_listener.zip into dir and returns the
// path to the Splash Screen.vi launcher.
func ExtractListener(dir string) (string, error) {
	listenerPath, err := listenerZipPath()
	if err != nil {
		return "", err
	}

	listenerZip, err := os.ReadFile(listenerPath)
	if err != nil {
		return "", fmt.Errorf("failed to read lv_listener archive %s: %w", listenerPath, err)
	}

	if err := extractZip(listenerZip, dir); err != nil {
		return "", fmt.Errorf("failed to extract lv_listener: %w", err)
	}
	launcher := filepath.Join(dir, "lv_listener", "Listener", "Listener Launcher", "Splash Screen.vi")
	if _, err := os.Stat(launcher); err != nil {
		return "", fmt.Errorf("extracted listener but Splash Screen.vi not found at %s: %w", launcher, err)
	}
	return launcher, nil
}

// ExtractLabVIEWIni writes the embedded LabVIEW.ini to dir and returns the path.
func ExtractLabVIEWIni(dir string) (string, error) {
	return Extract(dir, "LabVIEW.ini", LabVIEWIni)
}

// ExtractToImages writes the embedded toimages archive into dir.
func ExtractToImages(dir string) error {
	return extractZip(ToImagesZip, dir)
}

// EmbeddedToImagesHash returns a stable hash for the embedded toimages assets.
func EmbeddedToImagesHash() (string, error) {
	hasher := sha256.New()
	if _, err := hasher.Write(ToImagesZip); err != nil {
		return "", fmt.Errorf("failed to hash embedded toimages assets: %w", err)
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// ExtractZipFile reads a zip archive from zipPath and extracts it into dir.
func ExtractZipFile(zipPath string, dir string) error {
	data, err := os.ReadFile(zipPath)
	if err != nil {
		return fmt.Errorf("failed to read zip archive %s: %w", zipPath, err)
	}
	return ExtractZipData(data, dir)
}

// ExtractZipData extracts zip archive bytes into dir.
func ExtractZipData(data []byte, dir string) error {
	return extractZip(data, dir)
}

func generatorDependenciesZipPath() (string, error) {
	root, err := repoRoot()
	if err != nil {
		return "", err
	}

	path := filepath.Join(root, "src", "labview", "vi-xml", "VIs", "LV AI Core.zip")
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("LV AI Core archive not found at %s: %w", path, err)
	}

	return path, nil
}

func listenerZipPath() (string, error) {
	root, err := repoRoot()
	if err != nil {
		return "", err
	}

	path := filepath.Join(root, "src", "shared", "labview", "lv_listener.zip")
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("lv_listener archive not found at %s: %w", path, err)
	}

	return path, nil
}

// extractZip extracts a zip archive into dir.
func extractZip(data []byte, dir string) error {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return fmt.Errorf("failed to open zip: %w", err)
	}

	baseDir, err := filepath.Abs(dir)
	if err != nil {
		return fmt.Errorf("failed to resolve extraction dir %s: %w", dir, err)
	}
	baseDir = filepath.Clean(baseDir)

	for _, f := range r.File {
		if filepath.IsAbs(f.Name) || filepath.VolumeName(f.Name) != "" || strings.HasPrefix(f.Name, "/") {
			return fmt.Errorf("zip entry %q uses an absolute or volume-rooted path", f.Name)
		}

		target := filepath.Join(baseDir, f.Name)
		target = filepath.Clean(target)
		if target != baseDir && !strings.HasPrefix(target, baseDir+string(os.PathSeparator)) {
			return fmt.Errorf("zip entry %q escapes extraction dir %s", f.Name, baseDir)
		}

		mode := f.Mode()
		if mode.IsDir() {
			if err := os.MkdirAll(target, 0o700); err != nil {
				return fmt.Errorf("failed to create dir %s: %w", target, err)
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return fmt.Errorf("failed to create parent dir for %s: %w", target, err)
		}

		rc, err := f.Open()
		if err != nil {
			return fmt.Errorf("failed to open %s in zip: %w", f.Name, err)
		}

		if mode&os.ModeSymlink != 0 {
			linkTarget, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return fmt.Errorf("failed to read symlink %s in zip: %w", f.Name, err)
			}
			if err := os.Symlink(string(linkTarget), target); err != nil {
				return fmt.Errorf("failed to create symlink %s -> %s: %w", target, string(linkTarget), err)
			}
			continue
		}

		outFile, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
		if err != nil {
			rc.Close()
			return fmt.Errorf("failed to create %s: %w", target, err)
		}

		if _, err := io.Copy(outFile, rc); err != nil {
			outFile.Close()
			rc.Close()
			return fmt.Errorf("failed to write %s: %w", target, err)
		}
		outFile.Close()
		rc.Close()
	}

	return nil
}
