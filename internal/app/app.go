package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
)

// Run executes the application. It is separated from main so behavior stays
// testable without shelling out to the compiled binary.
func Run(ctx context.Context, args []string, stdout io.Writer, logger *slog.Logger, version string) error {
	return run(ctx, args, stdout, logger, version, execCommandExecutor{})
}

// run wires argument parsing, ASAN setup, test discovery, artifact lifecycle,
// and result reporting together. The executor parameter keeps command execution
// replaceable in tests.
func run(ctx context.Context, args []string, stdout io.Writer, logger *slog.Logger, version string, executor commandExecutor) error {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}

	cfg, err := parseArgs(args, stdout)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if cfg.showVersion {
		_, err := fmt.Fprintf(stdout, "mogo-tester %s\n", version)
		return err
	}

	if cfg.asan {
		runtime, err := locateASANRuntime()
		if err != nil {
			return err
		}
		cfg.asanRuntime = runtime
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	paths, err := discoverTests(cfg.testPaths)
	if err != nil {
		return err
	}

	artifactDir, err := os.MkdirTemp("", "mogo-tester-*")
	if err != nil {
		return fmt.Errorf("create artifact directory: %w", err)
	}
	if !cfg.keepArtifacts {
		defer func() {
			if removeErr := os.RemoveAll(artifactDir); removeErr != nil {
				logger.Error("remove artifact directory", "path", artifactDir, "error", removeErr)
			}
		}()
	}

	if len(cfg.precompilePaths) > 0 {
		if err := precompileModules(ctx, cfg, artifactDir, stdout, executor); err != nil {
			return err
		}
		cfg.precompileImportDir = artifactDir
	}

	logger.Info("running mojo tests", "paths", cfg.testPaths, "count", len(paths), "parallel", cfg.parallel)

	summary, err := runTests(ctx, cfg, paths, artifactDir, stdout, executor)
	if err != nil {
		return err
	}

	if cfg.keepArtifacts {
		if _, err := fmt.Fprintf(stdout, "artifacts: %s\n", artifactDir); err != nil {
			return err
		}
	}

	if summary.failed() {
		return fmt.Errorf("test run failed: %d compile failure(s), %d run failure(s)", summary.failedCompile, summary.failedRun)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		return nil
	}
}
