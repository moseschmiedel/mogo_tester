package app

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/creack/pty"
)

type processResult struct {
	stdout   string
	stderr   string
	combined bool
	exitCode int
	duration time.Duration
	err      error
}

type commandOptions struct {
	fakeTTY bool
	env     []string
}

type commandExecutor interface {
	Run(ctx context.Context, opts commandOptions, name string, args ...string) processResult
}

type execCommandExecutor struct{}

// Run executes a command with either ordinary pipes or a fake TTY, falling back
// to pipes when PTYs are not supported on the platform.
func (execCommandExecutor) Run(ctx context.Context, opts commandOptions, name string, args ...string) processResult {
	if opts.fakeTTY {
		result := runCommandWithTTY(ctx, opts, name, args...)
		if !errors.Is(result.err, pty.ErrUnsupported) {
			return result
		}
	}
	return runCommandWithPipes(ctx, opts, name, args...)
}

// runCommandWithPipes captures stdout and stderr separately using ordinary
// os/exec pipes.
func runCommandWithPipes(ctx context.Context, opts commandOptions, name string, args ...string) processResult {
	start := time.Now()
	cmd := exec.CommandContext(ctx, name, args...)
	applyCommandOptions(cmd, opts)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		exitCode = -1
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		}
	}

	return processResult{
		stdout:   stdout.String(),
		stderr:   stderr.String(),
		exitCode: exitCode,
		duration: time.Since(start),
		err:      err,
	}
}

// applyCommandOptions applies environment overrides to an exec.Cmd.
func applyCommandOptions(cmd *exec.Cmd, opts commandOptions) {
	if len(opts.env) > 0 {
		cmd.Env = append(os.Environ(), opts.env...)
	}
}

// runCommandWithTTY captures stdout and stderr through a pseudo-terminal so
// terminal-aware test binaries behave like they are running interactively.
func runCommandWithTTY(ctx context.Context, opts commandOptions, name string, args ...string) processResult {
	start := time.Now()
	cmd := exec.CommandContext(ctx, name, args...)
	applyCommandOptions(cmd, opts)

	ptmx, tty, err := pty.Open()
	if err != nil {
		return processResult{exitCode: -1, duration: time.Since(start), err: err}
	}
	defer func() { _ = ptmx.Close() }()

	cmd.Stdout = tty
	cmd.Stderr = tty

	var output bytes.Buffer
	copyDone := make(chan struct{})
	go func() {
		_, _ = io.Copy(&output, ptmx)
		close(copyDone)
	}()

	err = cmd.Start()
	_ = tty.Close()
	if err == nil {
		err = cmd.Wait()
	}
	_ = ptmx.Close()
	<-copyDone

	exitCode := 0
	if err != nil {
		exitCode = -1
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		}
	}

	return processResult{
		stdout:   normalizePTYOutput(output.String()),
		combined: true,
		exitCode: exitCode,
		duration: time.Since(start),
		err:      err,
	}
}

// normalizePTYOutput converts CRLF sequences produced by PTY-backed commands to
// LF so report output is stable across platforms.
func normalizePTYOutput(output string) string {
	return strings.ReplaceAll(output, "\r\n", "\n")
}

// commandSucceeded reports whether command execution completed with exit code
// zero and no execution error.
func commandSucceeded(result processResult) bool {
	return result.err == nil && result.exitCode == 0
}
