package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

var errNoTests = errors.New("no .mojo test files found")

type fileResult struct {
	path       string
	compileCmd []string
	compile    processResult
	run        processResult
	didRun     bool
	binaryPath string
}

func (r fileResult) passed() bool {
	return commandSucceeded(r.compile) && r.didRun && commandSucceeded(r.run)
}

func (r fileResult) compileFailed() bool {
	return !commandSucceeded(r.compile)
}

func (r fileResult) runFailed() bool {
	return commandSucceeded(r.compile) && (!r.didRun || !commandSucceeded(r.run))
}

type runSummary struct {
	total         int
	passed        int
	failedCompile int
	failedRun     int
	elapsed       time.Duration
}

func (s runSummary) failed() bool {
	return s.failedCompile > 0 || s.failedRun > 0
}

// discoverTests returns .mojo test files selected by paths. Directory operands
// contribute sorted top-level .mojo files, while file operands contribute that
// file directly. Nested directories are intentionally ignored.
func discoverTests(testPaths []string) ([]string, error) {
	var paths []string
	for _, testPath := range testPaths {
		info, err := os.Stat(testPath)
		if err != nil {
			return nil, fmt.Errorf("discover tests in %s: %w", testPath, err)
		}

		if info.IsDir() {
			dirPaths, err := discoverTestsInDir(testPath)
			if err != nil {
				if errors.Is(err, errNoTests) {
					continue
				}
				return nil, err
			}
			paths = append(paths, dirPaths...)
			continue
		}

		if !strings.HasSuffix(filepath.Base(testPath), ".mojo") {
			return nil, fmt.Errorf("test file %s must have .mojo extension", testPath)
		}
		paths = append(paths, testPath)
	}

	if len(paths) == 0 {
		return nil, fmt.Errorf("%w in %s", errNoTests, strings.Join(testPaths, ", "))
	}

	return paths, nil
}

func discoverTestsInDir(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("discover tests in %s: %w", dir, err)
	}

	var paths []string
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".mojo") {
			continue
		}
		paths = append(paths, filepath.Join(dir, entry.Name()))
	}

	sort.Strings(paths)
	if len(paths) == 0 {
		return nil, fmt.Errorf("%w in %s", errNoTests, dir)
	}

	return paths, nil
}

// runTests schedules discovered paths across the configured worker pool and
// streams progress and results through the reporting goroutine.
func runTests(ctx context.Context, cfg config, paths []string, artifactDir string, stdout io.Writer, executor commandExecutor) (runSummary, error) {
	start := time.Now()
	jobs := make(chan string)
	events := make(chan runEvent)
	summaryCh := make(chan printOutcome, 1)

	go printEvents(stdout, events, start, !cfg.noColor, len(paths), summaryCh)

	var workers sync.WaitGroup
	for i := 0; i < cfg.parallel; i++ {
		workers.Go(func() {
			for path := range jobs {
				result := runOne(ctx, cfg, artifactDir, path, executor, events)
				events <- runEvent{result: &result}
			}
		})
	}

	for _, path := range paths {
		select {
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			close(events)
			outcome := <-summaryCh
			if outcome.err != nil {
				return outcome.summary, outcome.err
			}
			return outcome.summary, ctx.Err()
		case jobs <- path:
		}
	}

	close(jobs)
	workers.Wait()
	close(events)

	outcome := <-summaryCh
	if outcome.err != nil {
		return outcome.summary, outcome.err
	}
	return outcome.summary, nil
}

// runOne compiles one Mojo file, runs the produced binary when compilation
// succeeds, and records enough detail to print a complete result block.
func runOne(ctx context.Context, cfg config, artifactDir, path string, executor commandExecutor, events chan<- runEvent) fileResult {
	result := fileResult{
		path:       path,
		binaryPath: binaryPathFor(artifactDir, path),
	}

	useASAN := cfg.asan && !fileSkipsASAN(path)
	buildArgs := make([]string, 0, 6+len(cfg.mojoBuildArgs)+len(cfg.asanRuntime.buildArgs))
	buildArgs = append(buildArgs, "build")
	buildArgs = append(buildArgs, cfg.mojoBuildArgs...)
	if useASAN {
		buildArgs = append(buildArgs, "--sanitize", "address")
		buildArgs = append(buildArgs, cfg.asanRuntime.buildArgs...)
	}
	buildArgs = append(buildArgs, "-o", result.binaryPath, path)
	result.compileCmd = append([]string{"mojo"}, buildArgs...)

	events <- runEvent{progress: progressUpdate{path: path, stage: stageCompiling}}
	result.compile = executor.Run(ctx, commandOptions{}, "mojo", buildArgs...)
	if !commandSucceeded(result.compile) {
		events <- runEvent{progress: progressUpdate{path: path, stage: stageDone}}
		return result
	}

	result.didRun = true
	runOptions := commandOptions{fakeTTY: true}
	if useASAN {
		runOptions.env = []string{cfg.asanRuntime.preloadVar + "=" + cfg.asanRuntime.libPath}
	}
	events <- runEvent{progress: progressUpdate{path: path, stage: stageRunning}}
	result.run = executor.Run(ctx, runOptions, result.binaryPath)
	if useASAN && asanReported(result.run) {
		result.run = markASANFailure(result.run)
	}
	events <- runEvent{progress: progressUpdate{path: path, stage: stageDone}}
	return result
}

// binaryPathFor derives a stable, filesystem-safe artifact path for a source
// file and adds a path hash so identical basenames do not collide.
func binaryPathFor(artifactDir, path string) string {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	base = sanitizeBinaryName(base)
	sum := sha256.Sum256([]byte(path))
	name := fmt.Sprintf("%s-%s", base, hex.EncodeToString(sum[:])[:10])
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(artifactDir, name)
}

// sanitizeBinaryName replaces characters that are awkward or unsafe in binary
// filenames while keeping readable ASCII names intact.
func sanitizeBinaryName(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "test"
	}
	return b.String()
}
