package app

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

type asanRuntime struct {
	libPath    string
	preloadVar string
	buildArgs  []string
}

// locateASANRuntime resolves the AddressSanitizer runtime for the current
// platform using CC when set, or clang otherwise.
func locateASANRuntime() (asanRuntime, error) {
	clangCmd := os.Getenv("CC")
	if clangCmd == "" {
		clangCmd = "clang"
	}
	return locateASANRuntimeWith(runtime.GOOS+"/"+runtime.GOARCH, clangCmd)
}

// locateASANRuntimeWith queries a clang resource directory and returns the
// build and preload settings needed to link and run ASAN-enabled Mojo binaries.
func locateASANRuntimeWith(platform, clangCmd string) (asanRuntime, error) {
	var pattern, preloadVar, hint string
	switch platform {
	case "darwin/arm64":
		pattern = "libclang_rt.asan_osx_dynamic.dylib"
		preloadVar = "DYLD_INSERT_LIBRARIES"
		hint = "Install it with: pixi add clang --platform osx-arm64"
	case "linux/amd64":
		pattern = "libclang_rt.asan*.so"
		preloadVar = "LD_PRELOAD"
		hint = "Install it with: pixi add clang --platform linux-64"
	default:
		return asanRuntime{}, fmt.Errorf("AddressSanitizer runtime lookup is not configured for %s", platform)
	}

	resourceDir, resolveErr := resolveClangResourceDir(clangCmd)
	var libPath string
	var findErr error
	if resolveErr == nil {
		libPath, findErr = findFirstMatching(filepath.Join(resourceDir, "lib"), pattern)
	}
	if findErr != nil {
		return asanRuntime{}, fmt.Errorf("find AddressSanitizer runtime: %w", findErr)
	}
	if libPath == "" {
		message := fmt.Sprintf("compatible AddressSanitizer runtime not found for %s\nCompiler queried: %s --print-resource-dir", platform, clangCmd)
		if resourceDir != "" {
			message += fmt.Sprintf("\nCompiler resource dir: %s\nSearched below: %s", resourceDir, filepath.Join(resourceDir, "lib"))
		} else {
			message += "\nCompiler resource dir: <unavailable>"
		}
		message += "\n" + hint
		if resolveErr != nil {
			message += fmt.Sprintf("\nResolve error: %v", resolveErr)
		}
		return asanRuntime{}, errors.New(message)
	}

	return asanRuntime{
		libPath:    libPath,
		preloadVar: preloadVar,
		buildArgs:  []string{"--external-libasan", libPath},
	}, nil
}

// resolveClangResourceDir returns the compiler resource directory reported by
// clang --print-resource-dir.
func resolveClangResourceDir(clangCmd string) (string, error) {
	output, err := exec.Command(clangCmd, "--print-resource-dir").Output()
	if err != nil {
		return "", err
	}
	resourceDir := strings.TrimSpace(string(output))
	if resourceDir == "" {
		return "", errors.New("empty compiler resource directory")
	}
	return resourceDir, nil
}

// findFirstMatching walks root and returns the lexicographically first file
// whose basename matches pattern.
func findFirstMatching(root, pattern string) (string, error) {
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}

	var matches []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ok, err := filepath.Match(pattern, d.Name())
		if err != nil {
			return err
		}
		if ok {
			matches = append(matches, path)
		}
		return nil
	})
	if err != nil || len(matches) == 0 {
		return "", err
	}
	sort.Strings(matches)
	return matches[0], nil
}

// fileSkipsASAN reports whether a source file contains the opt-out marker.
func fileSkipsASAN(path string) bool {
	content, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(string(content), "# SKIP_ASAN")
}

// fileSkipsDebug reports whether a source file contains the debug opt-out marker.
func fileSkipsDebug(path string) bool {
	content, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(string(content), "# SKIP_DEBUG")
}

// asanReported detects ASAN reports in process output, including cases where
// the binary exits with status zero despite printing an error.
func asanReported(result processResult) bool {
	output := result.stdout + result.stderr
	return strings.Contains(output, "ERROR:") && strings.Contains(output, "AddressSanitizer")
}

// markASANFailure converts an ASAN report into a failed process result.
func markASANFailure(result processResult) processResult {
	if result.exitCode == 0 {
		result.exitCode = 1
	}
	if result.err == nil {
		result.err = errors.New("AddressSanitizer error detected")
	}
	return result
}
