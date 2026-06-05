package app

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
)

var errNoTests = errors.New("no top-level .mojo files found")

type config struct {
	testDir       string
	parallel      int
	mojoBuildArgs []string
	keepArtifacts bool
	noColor       bool
	showVersion   bool
	asan          bool
	asanRuntime   asanRuntime
}

type repeatableStrings []string

func (r *repeatableStrings) String() string {
	return strings.Join(*r, ",")
}

func (r *repeatableStrings) Set(value string) error {
	*r = append(*r, value)
	return nil
}

type processResult struct {
	stdout   string
	stderr   string
	combined bool
	exitCode int
	duration time.Duration
	err      error
}

type asanRuntime struct {
	libPath    string
	preloadVar string
	buildArgs  []string
}

type commandOptions struct {
	fakeTTY bool
	env     []string
}

type commandExecutor interface {
	Run(ctx context.Context, opts commandOptions, name string, args ...string) processResult
}

type execCommandExecutor struct{}

func (execCommandExecutor) Run(ctx context.Context, opts commandOptions, name string, args ...string) processResult {
	if opts.fakeTTY {
		result := runCommandWithTTY(ctx, opts, name, args...)
		if !errors.Is(result.err, pty.ErrUnsupported) {
			return result
		}
	}
	return runCommandWithPipes(ctx, opts, name, args...)
}

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

func applyCommandOptions(cmd *exec.Cmd, opts commandOptions) {
	if len(opts.env) > 0 {
		cmd.Env = append(os.Environ(), opts.env...)
	}
}

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

func normalizePTYOutput(output string) string {
	return strings.ReplaceAll(output, "\r\n", "\n")
}

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

// Run executes the application. It is separated from main so behavior stays
// testable without shelling out to the compiled binary.
func Run(ctx context.Context, args []string, stdout io.Writer, logger *slog.Logger, version string) error {
	return run(ctx, args, stdout, logger, version, execCommandExecutor{})
}

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

	paths, err := discoverTests(cfg.testDir)
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

	logger.Info("running mojo tests", "dir", cfg.testDir, "count", len(paths), "parallel", cfg.parallel)

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

func parseArgs(args []string, output io.Writer) (config, error) {
	cfg := config{parallel: runtime.NumCPU()}
	var mojoBuildArgs string

	flags := flag.NewFlagSet("mogo-tester", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.Usage = func() {
		printUsage(output, cfg.parallel)
	}
	flags.IntVar(&cfg.parallel, "parallel", cfg.parallel, "maximum number of tests to compile and run concurrently")
	flags.Var((*repeatableStrings)(&cfg.mojoBuildArgs), "mojo-build-arg", "additional argument passed to mojo build; may be repeated")
	flags.StringVar(&mojoBuildArgs, "mojo-build-args", "", "space-separated arguments passed to mojo build")
	flags.BoolVar(&cfg.keepArtifacts, "keep-artifacts", false, "keep compiled binaries and print the artifact directory")
	flags.BoolVar(&cfg.noColor, "no-color", false, "disable colored output")
	flags.BoolVar(&cfg.asan, "asan", false, "build and run tests with AddressSanitizer enabled")
	flags.BoolVar(&cfg.showVersion, "version", false, "print version and exit")

	if err := flags.Parse(reorderOptions(args)); err != nil {
		return config{}, err
	}

	if cfg.parallel < 1 {
		return config{}, fmt.Errorf("parallel must be >= 1")
	}

	cfg.mojoBuildArgs = append(cfg.mojoBuildArgs, strings.Fields(mojoBuildArgs)...)

	remaining := flags.Args()
	if cfg.showVersion {
		if len(remaining) > 1 {
			return config{}, fmt.Errorf("usage: mogo-tester [options] <test-dir>")
		}
		return cfg, nil
	}

	if len(remaining) != 1 {
		return config{}, fmt.Errorf("usage: mogo-tester [options] <test-dir>")
	}

	cfg.testDir = remaining[0]
	return cfg, nil
}

func reorderOptions(args []string) []string {
	valueOptions := map[string]bool{
		"parallel":        true,
		"mojo-build-arg":  true,
		"mojo-build-args": true,
	}

	var options []string
	var operands []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			operands = append(operands, args[i+1:]...)
			break
		}
		if !isOption(arg) {
			operands = append(operands, arg)
			continue
		}

		options = append(options, arg)
		name, hasInlineValue := optionName(arg)
		if valueOptions[name] && !hasInlineValue && i+1 < len(args) {
			i++
			options = append(options, args[i])
		}
	}

	if len(operands) == 0 {
		return options
	}
	normalized := make([]string, 0, len(options)+1+len(operands))
	normalized = append(normalized, options...)
	normalized = append(normalized, "--")
	normalized = append(normalized, operands...)
	return normalized
}

func isOption(arg string) bool {
	return strings.HasPrefix(arg, "-") && arg != "-"
}

func optionName(arg string) (string, bool) {
	name := strings.TrimLeft(arg, "-")
	beforeValue, _, hasValue := strings.Cut(name, "=")
	if hasValue {
		return beforeValue, true
	}
	return name, false
}

func printUsage(output io.Writer, defaultParallel int) {
	fmt.Fprintf(output, "Usage: mogo-tester [OPTION...] TEST-DIR\n\n")
	fmt.Fprintf(output, "Compile and run top-level Mojo test files in TEST-DIR.\n\n")
	fmt.Fprintf(output, "Options:\n")
	fmt.Fprintf(output, "  --parallel N              maximum concurrent compile/run jobs (default: %d)\n", defaultParallel)
	fmt.Fprintf(output, "  --mojo-build-arg VALUE    extra argument passed to mojo build; may be repeated\n")
	fmt.Fprintf(output, "  --mojo-build-args VALUE   space-separated arguments passed to mojo build\n")
	fmt.Fprintf(output, "  --keep-artifacts          keep compiled binaries and print the artifact directory\n")
	fmt.Fprintf(output, "  --no-color                disable colored output\n")
	fmt.Fprintf(output, "  --asan                    build and run tests with AddressSanitizer enabled\n")
	fmt.Fprintf(output, "  --version                 print version and exit\n")
	fmt.Fprintf(output, "  --help                    display this help and exit\n")
}

func locateASANRuntime() (asanRuntime, error) {
	platform := runtime.GOOS + "/" + runtime.GOARCH
	var libName, preloadVar, hint string
	switch platform {
	case "darwin/arm64":
		libName = "libclang_rt.asan_osx_dynamic.dylib"
		preloadVar = "DYLD_INSERT_LIBRARIES"
		hint = "Install it with: pixi add compiler-rt --platform osx-arm64"
	case "linux/amd64":
		libName = "libclang_rt.asan-x86_64.so"
		preloadVar = "LD_PRELOAD"
		hint = "Install it with: pixi add compiler-rt --platform linux-64"
	default:
		return asanRuntime{}, fmt.Errorf("AddressSanitizer runtime lookup is not configured for %s", platform)
	}

	libPath, err := findFirst(filepath.Join(".pixi", "envs", "test"), libName)
	if err != nil {
		return asanRuntime{}, fmt.Errorf("find AddressSanitizer runtime: %w", err)
	}
	if libPath == "" {
		return asanRuntime{}, fmt.Errorf("compatible AddressSanitizer runtime not found for %s. %s", platform, hint)
	}

	return asanRuntime{
		libPath:    libPath,
		preloadVar: preloadVar,
		buildArgs:  []string{"--external-libasan", libPath},
	}, nil
}

func findFirst(root, name string) (string, error) {
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}

	var match string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if d.Name() == name {
			match = path
			return filepath.SkipAll
		}
		return nil
	})
	return match, err
}

func discoverTests(dir string) ([]string, error) {
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

func runTests(ctx context.Context, cfg config, paths []string, artifactDir string, stdout io.Writer, executor commandExecutor) (runSummary, error) {
	start := time.Now()
	jobs := make(chan string)
	results := make(chan fileResult)
	summaryCh := make(chan printOutcome, 1)

	go printResults(stdout, results, start, !cfg.noColor, summaryCh)

	var workers sync.WaitGroup
	for i := 0; i < cfg.parallel; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for path := range jobs {
				results <- runOne(ctx, cfg, artifactDir, path, executor)
			}
		}()
	}

	for _, path := range paths {
		select {
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			close(results)
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
	close(results)

	outcome := <-summaryCh
	if outcome.err != nil {
		return outcome.summary, outcome.err
	}
	return outcome.summary, nil
}

func runOne(ctx context.Context, cfg config, artifactDir, path string, executor commandExecutor) fileResult {
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

	result.compile = executor.Run(ctx, commandOptions{}, "mojo", buildArgs...)
	if !commandSucceeded(result.compile) {
		return result
	}

	result.didRun = true
	runOptions := commandOptions{fakeTTY: true}
	if useASAN {
		runOptions.env = []string{cfg.asanRuntime.preloadVar + "=" + cfg.asanRuntime.libPath}
	}
	result.run = executor.Run(ctx, runOptions, result.binaryPath)
	if useASAN && asanReported(result.run) {
		result.run = markASANFailure(result.run)
	}
	return result
}

func fileSkipsASAN(path string) bool {
	content, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(string(content), "# SKIP_ASAN")
}

func asanReported(result processResult) bool {
	output := result.stdout + result.stderr
	return strings.Contains(output, "ERROR:") && strings.Contains(output, "AddressSanitizer")
}

func markASANFailure(result processResult) processResult {
	if result.exitCode == 0 {
		result.exitCode = 1
	}
	if result.err == nil {
		result.err = errors.New("AddressSanitizer error detected")
	}
	return result
}

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

type printOutcome struct {
	summary runSummary
	err     error
}

func printResults(stdout io.Writer, results <-chan fileResult, start time.Time, colorEnabled bool, done chan<- printOutcome) {
	summary := runSummary{}
	var err error
	colors := outputColors{enabled: colorEnabled}

	for result := range results {
		summary.total++
		switch {
		case result.passed():
			summary.passed++
		case result.compileFailed():
			summary.failedCompile++
		case result.runFailed():
			summary.failedRun++
		}

		if printErr := printResultBlock(stdout, result, colors); printErr != nil && err == nil {
			err = printErr
		}
	}

	summary.elapsed = time.Since(start)
	if printErr := printSummary(stdout, summary, colors); printErr != nil && err == nil {
		err = printErr
	}

	done <- printOutcome{summary: summary, err: err}
}

func printResultBlock(w io.Writer, result fileResult, colors outputColors) error {
	if _, err := fmt.Fprintf(w, "%s\n", colors.header(fmt.Sprintf("=== %s ===", result.path))); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "%s %s\n", colors.label("compile command:"), colors.dim(formatCommand(result.compileCmd))); err != nil {
		return err
	}
	if err := printProcess(w, "compile", result.compile, colors); err != nil {
		return err
	}
	if result.didRun {
		if err := printProcess(w, "run", result.run, colors); err != nil {
			return err
		}
	} else if _, err := fmt.Fprintf(w, "run: %s\n", colors.skip("SKIPPED")); err != nil {
		return err
	}

	status := "FAIL"
	statusText := colors.fail(status)
	if result.passed() {
		status = "PASS"
		statusText = colors.pass(status)
	}
	_, err := fmt.Fprintf(w, "%s %s\n\n", colors.label("result:"), statusText)
	return err
}

func printProcess(w io.Writer, label string, result processResult, colors outputColors) error {
	status := "PASS"
	statusText := colors.pass(status)
	if !commandSucceeded(result) {
		status = "FAIL"
		statusText = colors.fail(status)
	}

	if _, err := fmt.Fprintf(w, "%s: %s exit=%d duration=%s\n", label, statusText, result.exitCode, result.duration); err != nil {
		return err
	}
	if result.combined {
		return printCaptured(w, label+" output", combinedOutputWithError(result))
	}
	if err := printCaptured(w, label+" stdout", result.stdout); err != nil {
		return err
	}
	if err := printCaptured(w, label+" stderr", stderrWithError(result)); err != nil {
		return err
	}
	return nil
}

func printCaptured(w io.Writer, label, value string) error {
	if _, err := fmt.Fprintf(w, "%s:\n", label); err != nil {
		return err
	}
	if value != "" {
		if _, err := io.WriteString(w, value); err != nil {
			return err
		}
		if !strings.HasSuffix(value, "\n") {
			if _, err := fmt.Fprintln(w); err != nil {
				return err
			}
		}
	}
	return nil
}

func printSummary(w io.Writer, summary runSummary, colors outputColors) error {
	_, err := fmt.Fprintf(
		w,
		"%s total=%d passed=%d failed_compile=%d failed_run=%d elapsed=%s\n",
		colors.summary("Summary:"),
		summary.total,
		summary.passed,
		summary.failedCompile,
		summary.failedRun,
		summary.elapsed,
	)
	return err
}

func commandSucceeded(result processResult) bool {
	return result.err == nil && result.exitCode == 0
}

type outputColors struct {
	enabled bool
}

func (c outputColors) header(value string) string {
	return c.wrap("\x1b[36;1m", value)
}

func (c outputColors) summary(value string) string {
	return c.wrap("\x1b[36;1m", value)
}

func (c outputColors) label(value string) string {
	return c.wrap("\x1b[1m", value)
}

func (c outputColors) pass(value string) string {
	return c.wrap("\x1b[32m", value)
}

func (c outputColors) fail(value string) string {
	return c.wrap("\x1b[31m", value)
}

func (c outputColors) skip(value string) string {
	return c.wrap("\x1b[33m", value)
}

func (c outputColors) dim(value string) string {
	return c.wrap("\x1b[2m", value)
}

func (c outputColors) wrap(code, value string) string {
	if !c.enabled {
		return value
	}
	return code + value + "\x1b[0m"
}

func formatCommand(args []string) string {
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = quoteArg(arg)
	}
	return strings.Join(quoted, " ")
}

func quoteArg(arg string) string {
	if arg == "" {
		return "''"
	}
	if strings.IndexFunc(arg, func(r rune) bool {
		return r <= ' ' || strings.ContainsRune(`'"\\$&;()<>|*?[]{}!`+"\n\t", r)
	}) == -1 {
		return arg
	}
	return "'" + strings.ReplaceAll(arg, "'", `'\''`) + "'"
}

func stderrWithError(result processResult) string {
	if result.err == nil {
		return result.stderr
	}
	if result.stderr == "" {
		return result.err.Error()
	}
	if strings.HasSuffix(result.stderr, "\n") {
		return result.stderr + result.err.Error()
	}
	return result.stderr + "\n" + result.err.Error()
}

func combinedOutputWithError(result processResult) string {
	if result.err == nil || result.stdout != "" {
		return result.stdout
	}
	return result.err.Error()
}
