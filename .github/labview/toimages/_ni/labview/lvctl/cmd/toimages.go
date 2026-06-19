package cmd

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ni/testhub/src/labview/lvctl/vis"
	"github.com/ni/testhub/src/labview/lvctl/viserver"
)

// ToImagesCmd converts a VI to the JSON image payload emitted by lvctl's
// bundled toimages asset tree.
type ToImagesCmd struct {
	Path []string `arg:"" help:"Path(s) to the .vi file(s) to convert"`

	GetVIInfoVI string        `help:"Path to Get VI Info.vi" env:"LVCTL_TOIMAGES_VI" name:"get-vi-info-vi"`
	MaxFileSize int64         `help:"Maximum input file size in MiB" default:"10"`
	Timeout     time.Duration `help:"Operation timeout" default:"2m"`
	OutputDir   string        `help:"Write PNG images to this directory and output lightweight JSON with file references instead of inline base64" name:"output-dir"`
}

type toImagesLock struct {
	path string
	once sync.Once
}

const toImagesLockPIDFile = "pid"

func (c *ToImagesCmd) Run(globals *Globals) error {
	if len(c.Path) == 0 {
		return fmt.Errorf("at least one .vi path is required")
	}

	// Validate all paths up front before connecting to LabVIEW.
	maxBytes := c.MaxFileSize * 1024 * 1024
	for _, p := range c.Path {
		if err := validateVIPath(p, maxBytes); err != nil {
			return err
		}
	}

	getVIInfoPath := c.GetVIInfoVI
	if getVIInfoPath == "" {
		var err error
		getVIInfoPath, err = defaultGetVIInfoVIPath()
		if err != nil {
			return err
		}
	}

	absGetVIInfoPath, err := filepath.Abs(getVIInfoPath)
	if err != nil {
		return fmt.Errorf("failed to resolve Get VI Info.vi path: %w", err)
	}

	lock, err := acquireToImagesLock(c.Timeout)
	if err != nil {
		return err
	}
	defer lock.Close()

	session, err := viserver.Connect()
	if err != nil {
		return err
	}
	defer session.Close()

	// Single path: output raw JSON array (backward compatible).
	if len(c.Path) == 1 {
		jsonContent, err := viToImagesJSON(session, c.Timeout, absGetVIInfoPath, c.Path[0])
		if err != nil {
			return err
		}
		if c.OutputDir != "" {
			return writeImagesToDir(jsonContent, c.OutputDir)
		}
		_, err = os.Stdout.Write(jsonContent)
		return err
	}

	// Multiple paths: output JSONL — one {"path":…,"images":…} per line.
	// Errors for individual VIs are logged to stderr; processing continues.
	enc := json.NewEncoder(os.Stdout)
	var lastErr error
	successCount := 0
	for _, p := range c.Path {
		jsonContent, err := viToImagesJSON(session, c.Timeout, absGetVIInfoPath, p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %s: %v\n", p, err)
			lastErr = err
			continue
		}
		if c.OutputDir != "" {
			// For multi-path with --output-dir, use a subdirectory per VI.
			subDir := filepath.Join(c.OutputDir, sanitizePathComponent(p))
			if err := writeImagesToDir(jsonContent, subDir); err != nil {
				fmt.Fprintf(os.Stderr, "error: %s: %v\n", p, err)
				lastErr = err
				continue
			}
			successCount++
			continue
		}
		var images json.RawMessage = jsonContent
		if err := enc.Encode(map[string]any{"path": p, "images": images}); err != nil {
			return err
		}
		successCount++
	}
	if successCount == 0 && lastErr != nil {
		fmt.Fprintf(os.Stderr, "error: all %d VIs failed, last error: %v\n", len(c.Path), lastErr)
	}
	return nil
}

func acquireToImagesLock(timeout time.Duration) (*toImagesLock, error) {
	lockPath, err := toImagesLockPath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o700); err != nil {
		return nil, fmt.Errorf("failed to create toimages lock parent: %w", err)
	}

	deadline := time.Now().Add(timeout)
	for {
		err := os.Mkdir(lockPath, 0o700)
		if err == nil {
			if err := writeToImagesLockPID(lockPath); err != nil {
				_ = os.Remove(lockPath)
				return nil, err
			}
			return &toImagesLock{path: lockPath}, nil
		}
		if !os.IsExist(err) {
			return nil, fmt.Errorf("failed to acquire toimages lock: %w", err)
		}
		stale, staleErr := isStaleToImagesLock(lockPath)
		if staleErr != nil {
			return nil, staleErr
		}
		if stale {
			// Use atomic rename to claim the stale lock. Only one process
			// wins the rename; losers get an error and simply retry.
			staleDest := lockPath + fmt.Sprintf(".stale.%d", os.Getpid())
			if renameErr := os.Rename(lockPath, staleDest); renameErr == nil {
				_ = os.RemoveAll(staleDest)
			}
			// Whether we won or lost the rename, retry Mkdir on next iteration.
			continue
		}
		if timeout > 0 && time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for another toimages conversion to finish")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func writeToImagesLockPID(lockPath string) error {
	pidPath := filepath.Join(lockPath, toImagesLockPIDFile)
	pid := strconv.Itoa(os.Getpid())
	if err := os.WriteFile(pidPath, []byte(pid), 0o600); err != nil {
		return fmt.Errorf("failed to write toimages lock pid: %w", err)
	}
	return nil
}

func isStaleToImagesLock(lockPath string) (bool, error) {
	pidPath := filepath.Join(lockPath, toImagesLockPIDFile)
	pidBytes, err := os.ReadFile(pidPath)
	if err != nil {
		if os.IsNotExist(err) {
			return true, nil
		}
		return false, fmt.Errorf("failed to read toimages lock pid: %w", err)
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(pidBytes)))
	if err != nil {
		return true, nil
	}
	if pid <= 0 {
		return true, nil
	}

	alive, err := processExists(pid)
	if err != nil {
		return false, fmt.Errorf("failed to inspect toimages lock pid %d: %w", pid, err)
	}
	return !alive, nil
}

func (l *toImagesLock) Close() {
	l.once.Do(func() {
		if l == nil || l.path == "" {
			return
		}
		_ = os.RemoveAll(l.path)
	})
}

func validateVIPath(path string, maxBytes int64) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("cannot access file %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("input path is a directory: %s", path)
	}
	if !strings.HasSuffix(strings.ToLower(path), ".vi") {
		return fmt.Errorf("expected a .vi file, got: %s", path)
	}
	if info.Size() > maxBytes {
		return fmt.Errorf("file size %d bytes exceeds maximum %d MiB", info.Size(), maxBytes/1024/1024)
	}
	return nil
}

func viToImagesJSON(session *viserver.Session, timeout time.Duration, absGetVIInfoPath string, viPath string) ([]byte, error) {
	absVIPath, err := filepath.Abs(viPath)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve absolute path: %w", err)
	}

	if _, err := os.Stat(absGetVIInfoPath); err != nil {
		return nil, fmt.Errorf("cannot access Get VI Info.vi %s: %w", absGetVIInfoPath, err)
	}

	return viToImagesJSONDirect(session, timeout, absGetVIInfoPath, absVIPath)
}

// viToImagesJSONDirect uses Get VI Info.vi directly to capture front panel
// images.
func viToImagesJSONDirect(session *viserver.Session, timeout time.Duration, getVIInfoPath string, absVIPath string) ([]byte, error) {
	// Dynamically discover search directories by reading the VI's callee paths
	// (property 640). This replaces hardcoded heuristics and ensures LabVIEW
	// can resolve all dependencies regardless of directory structure.
	searchDirs := discoverSearchDirs(session, absVIPath)

	// Warmup: run Get VI Info.vi once to ensure the target VI is loaded
	// into LabVIEW's memory. Without this, OpenVIFrontPanel has no effect
	// because the VI isn't fully loaded yet.
	slog.Debug("toimages direct: warmup call to load target VI")
	_, _ = session.RunVIRaw(
		timeout,
		getVIInfoPath,
		map[string]any{"VI Path in": viserver.PathValue(absVIPath)},
		[]string{"VI Info out"},
		searchDirs...,
	)

	// Open the target VI's front panel. Required for image capture — without
	// an open FP, Get VI Info.vi returns all-zero image data.
	slog.Debug("toimages direct: opening target FP", "viPath", absVIPath)
	if err := session.OpenVIFrontPanel(absVIPath); err != nil {
		slog.Warn("toimages direct: failed to open FP", "error", err)
	}
	// Brief pause for the front panel to render.
	time.Sleep(500 * time.Millisecond)

	// Call Get VI Info.vi to capture the front panel images.
	slog.Debug("toimages direct: calling Get VI Info.vi")
	result, err := session.RunVI(
		timeout,
		getVIInfoPath,
		map[string]any{"VI Path in": viserver.PathValue(absVIPath)},
		[]string{"VI Info out", "error out"},
	)
	if err != nil {
		return nil, fmt.Errorf("Get VI Info.vi failed: %w", err)
	}

	// Check for LabVIEW errors.
	if errCluster, ok := result["error out"].(map[int]any); ok {
		if status, ok := errCluster[0].(bool); ok && status {
			code := int32(0)
			if c, ok := errCluster[1].(int32); ok {
				code = c
			}
			source := ""
			if s, ok := errCluster[2].(string); ok {
				source = s
			}
			return nil, fmt.Errorf("Get VI Info.vi error %d: %s", code, source)
		}
	}

	// Parse the structured "VI Info out" cluster into JSON frames.
	viInfoOut, ok := result["VI Info out"].(map[int]any)
	if !ok {
		return nil, fmt.Errorf("VI Info out is not a cluster")
	}

	return buildToImagesJSON(viInfoOut)
}

// buildToImagesJSON converts the parsed "VI Info out" cluster into the JSON
// format expected by the toimages command.
func buildToImagesJSON(viInfoOut map[int]any) ([]byte, error) {
	// Field 1 = Images array: [{Picture, Child Indices}, ...]
	imagesArr, ok := viInfoOut[1].([]any)
	if !ok {
		return nil, fmt.Errorf("Images field is not an array")
	}

	type jsonFrame struct {
		Base64Image  string `json:"Base64 Image"`
		Position     *struct {
			Left   int `json:"Left"`
			Top    int `json:"Top"`
			Width  int `json:"Width"`
			Height int `json:"Height"`
		} `json:"Position,omitempty"`
		ChildIndices []int `json:"Child Indices,omitempty"`
	}

	frames := make([]jsonFrame, 0, len(imagesArr))
	for i, frame := range imagesArr {
		frameCluster, ok := frame.(map[int]any)
		if !ok {
			return nil, fmt.Errorf("frame %d: not a cluster", i)
		}

		// Field 0 = Picture cluster (Pict2 structure)
		picCluster, ok := frameCluster[0].(map[int]any)
		if !ok {
			return nil, fmt.Errorf("frame %d: picture not a cluster", i)
		}

		pic, err := viserver.ExtractPictureData(picCluster)
		if err != nil {
			return nil, fmt.Errorf("frame %d: %w", i, err)
		}

		b64, err := pic.ToBase64PNG()
		if err != nil {
			return nil, fmt.Errorf("frame %d: PNG conversion: %w", i, err)
		}

		f := jsonFrame{
			Base64Image: b64,
		}

		// Add position from the picture bounds.
		if pic.Width() > 0 && pic.Height() > 0 {
			f.Position = &struct {
				Left   int `json:"Left"`
				Top    int `json:"Top"`
				Width  int `json:"Width"`
				Height int `json:"Height"`
			}{
				Left:   int(pic.Left),
				Top:    int(pic.Top),
				Width:  pic.Width(),
				Height: pic.Height(),
			}
		}

		// Field 1 = Child Indices array
		if childArr, ok := frameCluster[1].([]any); ok && len(childArr) > 0 {
			f.ChildIndices = make([]int, 0, len(childArr))
			for _, ci := range childArr {
				if idx, ok := ci.(int32); ok {
					f.ChildIndices = append(f.ChildIndices, int(idx))
				}
			}
		}

		frames = append(frames, f)
	}

	return json.Marshal(frames)
}

// discoverSearchDirs reads a VI's callee paths (property 640) and returns the
// unique directories that contain those callees, plus the VI's own directory.
// This dynamically determines what LabVIEW needs in its search path to resolve
// all dependencies, without hardcoding assumptions about directory layout.
func discoverSearchDirs(session *viserver.Session, absVIPath string) []string {
	// Always include the VI's own directory as a baseline.
	viDir := filepath.Dir(absVIPath)
	dirs := map[string]struct{}{viDir: {}}

	calleePaths, err := session.GetVICalleesPaths(absVIPath)
	if err != nil {
		slog.Warn("discoverSearchDirs: failed to read callee paths, using VI dir only",
			"viPath", absVIPath, "error", err)
		return []string{viDir}
	}

	for _, p := range calleePaths {
		if p == "" {
			continue
		}
		dir := filepath.Dir(p)
		dirs[dir] = struct{}{}
	}

	// Convert to sorted slice for deterministic behavior.
	result := make([]string, 0, len(dirs))
	for d := range dirs {
		result = append(result, d)
	}
	sort.Strings(result)
	slog.Debug("discoverSearchDirs", "viPath", absVIPath, "dirs", result)
	return result
}

func defaultGetVIInfoVIPath() (string, error) {
	cacheKey, err := vis.EmbeddedToImagesHash()
	if err != nil {
		return "", err
	}

	cacheDir, err := cachedToImagesDir(cacheKey)
	if err != nil {
		return "", err
	}

	baseDir, err := ensureToImagesAssets(cacheDir, vis.ExtractToImages)
	if err != nil {
		return "", err
	}

	return resolveToImagesGetVIInfoPath(baseDir)
}

func cachedToImagesDir(cacheKey string) (string, error) {
	cacheRoot, err := lvctlCacheRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheRoot, "lvctl", "toimages", cacheKey), nil
}

func toImagesLockPath() (string, error) {
	cacheRoot, err := lvctlCacheRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheRoot, "lvctl", "locks", "toimages.lock"), nil
}

func lvctlCacheRoot() (string, error) {
	cacheRoot := strings.TrimSpace(os.Getenv("LVCTL_CACHE_DIR"))
	if cacheRoot != "" {
		return cacheRoot, nil
	}

	cacheRoot, err := os.UserCacheDir()
	if err == nil {
		return cacheRoot, nil
	}

	return os.TempDir(), nil
}

func ensureToImagesAssets(cacheDir string, extract func(string) error) (string, error) {
	if baseDir, ok := findToImagesAssetsBase(cacheDir); ok {
		return baseDir, nil
	}

	if err := os.RemoveAll(cacheDir); err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("failed to clear stale toimages cache %s: %w", cacheDir, err)
	}
	if err := os.MkdirAll(filepath.Dir(cacheDir), 0o700); err != nil {
		return "", fmt.Errorf("failed to create toimages cache parent: %w", err)
	}

	tempDir, err := os.MkdirTemp(filepath.Dir(cacheDir), "extract-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp dir for toimages assets: %w", err)
	}
	defer os.RemoveAll(tempDir)

	if err := extract(tempDir); err != nil {
		return "", fmt.Errorf("failed to extract toimages assets: %w", err)
	}

	_, ok := findToImagesAssetsBase(tempDir)
	if !ok {
		missing, statErr := firstMissingToImagesAsset(filepath.Join(tempDir, "toimages"))
		return "", fmt.Errorf("required toimages asset missing at %s: %w", missing, statErr)
	}

	if err := os.Rename(tempDir, cacheDir); err != nil {
		if !os.IsExist(err) {
			return "", fmt.Errorf("failed to promote toimages cache %s: %w", cacheDir, err)
		}
		if _, ok := findToImagesAssetsBase(cacheDir); !ok {
			missing, statErr := firstMissingToImagesAsset(filepath.Join(cacheDir, "toimages"))
			return "", fmt.Errorf("required toimages asset missing at %s: %w", missing, statErr)
		}
	}

	baseDir, ok := findToImagesAssetsBase(cacheDir)
	if !ok {
		missing, statErr := firstMissingToImagesAsset(filepath.Join(cacheDir, "toimages"))
		return "", fmt.Errorf("required toimages asset missing at %s: %w", missing, statErr)
	}

	return baseDir, nil
}

func hasRequiredToImagesAssets(baseDir string) bool {
	_, err := firstMissingToImagesAsset(baseDir)
	return err == nil
}

func findToImagesAssetsBase(root string) (string, bool) {
	candidates := []string{
		filepath.Join(root, "toimages"),
		filepath.Join(root, "VIs"),
		root,
	}
	for _, candidate := range candidates {
		if hasRequiredToImagesAssets(candidate) {
			return candidate, true
		}
	}

	return "", false
}

func firstMissingToImagesAsset(baseDir string) (string, error) {
	requiredPaths := []string{
		filepath.Join(baseDir, "Get VI Info.vi"),
		filepath.Join(baseDir, "Combine Frame Data.vi"),
		filepath.Join(baseDir, "Compress Images.vi"),
		filepath.Join(baseDir, "Create Frame Array.vi"),
		filepath.Join(baseDir, "Get Frame-Owner Array.vi"),
		filepath.Join(baseDir, "Get Names.vi"),
	}
	for _, requiredPath := range requiredPaths {
		if _, err := os.Stat(requiredPath); err != nil {
			return requiredPath, err
		}
	}

	return "", nil
}

func resolveToImagesGetVIInfoPath(baseDir string) (string, error) {
	entryPath := filepath.Join(baseDir, "Get VI Info.vi")
	if _, err := os.Stat(entryPath); err == nil {
		return entryPath, nil
	}

	missing, statErr := firstMissingToImagesAsset(baseDir)
	if statErr != nil {
		return "", fmt.Errorf("required toimages asset missing at %s: %w", missing, statErr)
	}

	return "", fmt.Errorf("Get VI Info.vi not found under %s", baseDir)
}

// toImagesFrame mirrors the JSON structure produced by Get VI Info.vi.
// Used only for parsing in writeImagesToDir.
type toImagesFrame struct {
	Image       string `json:"Image,omitempty"`
	Base64Image string `json:"Base64 Image,omitempty"`
	Position    *struct {
		Left   int `json:"Left"`
		Top    int `json:"Top"`
		Width  int `json:"Width"`
		Height int `json:"Height"`
	} `json:"Position,omitempty"`
	Cluster *struct {
		Left   int `json:"Left"`
		Top    int `json:"Top"`
		Width  int `json:"Width"`
		Height int `json:"Height"`
	} `json:"Cluster,omitempty"`
	Children     []int `json:"Children,omitempty"`
	ChildIndices []int `json:"Child Indices,omitempty"`
}

// lightweightFrame is the output format when --output-dir is used.
// Base64 image data is replaced by a file path reference.
type lightweightFrame struct {
	ImageFile string `json:"ImageFile"`
	Position  *struct {
		Left   int `json:"Left"`
		Top    int `json:"Top"`
		Width  int `json:"Width"`
		Height int `json:"Height"`
	} `json:"Position,omitempty"`
	Cluster *struct {
		Left   int `json:"Left"`
		Top    int `json:"Top"`
		Width  int `json:"Width"`
		Height int `json:"Height"`
	} `json:"Cluster,omitempty"`
	Children     []int `json:"Children,omitempty"`
	ChildIndices []int `json:"Child Indices,omitempty"`
}

// writeImagesToDir decodes the inline JSON, writes each frame's image as a
// PNG file to outputDir, and writes lightweight JSON (with ImageFile references)
// to stdout.
func writeImagesToDir(jsonContent []byte, outputDir string) error {
	var frames []toImagesFrame
	if err := json.Unmarshal(jsonContent, &frames); err != nil {
		return fmt.Errorf("failed to parse toimages JSON for file extraction: %w", err)
	}

	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return fmt.Errorf("failed to create output directory %s: %w", outputDir, err)
	}

	lightFrames := make([]lightweightFrame, 0, len(frames))
	for i, frame := range frames {
		b64 := frame.Image
		if b64 == "" {
			b64 = frame.Base64Image
		}
		if b64 == "" {
			return fmt.Errorf("frame %d has no image data", i)
		}

		imgData, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			return fmt.Errorf("frame %d: failed to decode base64 image: %w", i, err)
		}

		filename := fmt.Sprintf("frame-%d.png", i)
		imgPath := filepath.Join(outputDir, filename)
		if err := os.WriteFile(imgPath, imgData, 0o644); err != nil {
			return fmt.Errorf("frame %d: failed to write image %s: %w", i, imgPath, err)
		}

		lightFrames = append(lightFrames, lightweightFrame{
			ImageFile:    filename,
			Position:     frame.Position,
			Cluster:      frame.Cluster,
			Children:     frame.Children,
			ChildIndices: frame.ChildIndices,
		})
	}

	output, err := json.Marshal(lightFrames)
	if err != nil {
		return fmt.Errorf("failed to marshal lightweight JSON: %w", err)
	}
	_, err = os.Stdout.Write(output)
	return err
}

// sanitizePathComponent creates a filesystem-safe name from a VI path for use
// as a subdirectory name when processing multiple VIs with --output-dir.
func sanitizePathComponent(path string) string {
	// Use the base name without extension, replacing unsafe chars.
	base := filepath.Base(path)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)
	replacer := strings.NewReplacer(" ", "_", "/", "_", "\\", "_", ":", "_")
	return replacer.Replace(name)
}

// dirExists returns true if the path exists and is a directory.
func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
