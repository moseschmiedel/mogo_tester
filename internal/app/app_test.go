package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseArgsRequiresTestPath(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	_, err := parseArgs(nil, &stdout)
	if err == nil {
		t.Fatal("parseArgs() error = nil, want error")
	}
	if !strings.Contains(err.Error(), "usage: mogo-tester [options] <test-path>...") {
		t.Fatalf("parseArgs() error = %q, want usage error", err)
	}
}

func TestParseArgsRejectsInvalidParallel(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	_, err := parseArgs([]string{"--parallel", "0", "tests"}, &stdout)
	if err == nil {
		t.Fatal("parseArgs() error = nil, want error")
	}
	if !strings.Contains(err.Error(), "parallel must be >= 1") {
		t.Fatalf("parseArgs() error = %q, want parallel error", err)
	}
}

func TestParseArgsPreservesRepeatedMojoBuildArgs(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	cfg, err := parseArgs([]string{
		"--parallel", "2",
		"--mojo-build-arg", "-I",
		"--mojo-build-arg", "src",
		"--keep-artifacts",
		"--no-color",
		"--asan",
		"tests",
	}, &stdout)
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}

	if cfg.parallel != 2 {
		t.Fatalf("parallel = %d, want 2", cfg.parallel)
	}
	if got, want := cfg.mojoBuildArgs, []string{"-I", "src"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("mojoBuildArgs = %#v, want %#v", got, want)
	}
	if !cfg.keepArtifacts {
		t.Fatal("keepArtifacts = false, want true")
	}
	if !cfg.noColor {
		t.Fatal("noColor = false, want true")
	}
	if !cfg.asan {
		t.Fatal("asan = false, want true")
	}
	if got, want := cfg.testPaths, []string{"tests"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("testPaths = %#v, want %#v", got, want)
	}
}

func TestParseArgsSplitsMojoBuildArgs(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	cfg, err := parseArgs([]string{
		"--mojo-build-arg", "-I",
		"--mojo-build-arg", "src",
		"--mojo-build-args", "--foo bar\t--baz",
		"tests",
	}, &stdout)
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}

	want := []string{"-I", "src", "--foo", "bar", "--baz"}
	if !reflect.DeepEqual(cfg.mojoBuildArgs, want) {
		t.Fatalf("mojoBuildArgs = %#v, want %#v", cfg.mojoBuildArgs, want)
	}
}

func TestParseArgsAllowsOptionsAfterTestPaths(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	cfg, err := parseArgs([]string{
		"tests",
		"extra.mojo",
		"--parallel", "2",
		"--mojo-build-arg", "-I",
		"--mojo-build-args=src --foo",
		"--no-color",
	}, &stdout)
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}

	if got, want := cfg.testPaths, []string{"tests", "extra.mojo"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("testPaths = %#v, want %#v", got, want)
	}
	if cfg.parallel != 2 {
		t.Fatalf("parallel = %d, want 2", cfg.parallel)
	}
	want := []string{"-I", "src", "--foo"}
	if !reflect.DeepEqual(cfg.mojoBuildArgs, want) {
		t.Fatalf("mojoBuildArgs = %#v, want %#v", cfg.mojoBuildArgs, want)
	}
	if !cfg.noColor {
		t.Fatal("noColor = false, want true")
	}
}

func TestParseArgsHonorsEndOfOptions(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	cfg, err := parseArgs([]string{"--", "--tests"}, &stdout)
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}

	if got, want := cfg.testPaths, []string{"--tests"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("testPaths = %#v, want %#v", got, want)
	}
}

func TestRunPrintsVersion(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer

	err := Run(context.Background(), []string{"--version"}, &stdout, nil, "test-version")
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}

	if got, want := stdout.String(), "mogo-tester test-version\n"; got != want {
		t.Fatalf("stdout = %q, want %q", got, want)
	}
}

func TestRunPrintsHelp(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer

	err := Run(context.Background(), []string{"--help"}, &stdout, nil, "test")
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}

	output := stdout.String()
	for _, want := range []string{
		"Usage: mogo-tester [OPTION...] TEST-PATH...\n",
		"--parallel N",
		"--mojo-build-arg VALUE",
		"--mojo-build-args VALUE",
		"--keep-artifacts",
		"--no-color",
		"--asan",
		"--version",
		"--help",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("help output missing %q:\n%s", want, output)
		}
	}
}

func TestDiscoverTestsTopLevelOnlySorted(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "b.mojo"), "")
	writeTestFile(t, filepath.Join(dir, "a.mojo"), "")
	writeTestFile(t, filepath.Join(dir, "note.txt"), "")

	nested := filepath.Join(dir, "nested")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(nested, "ignored.mojo"), "")

	paths, err := discoverTests([]string{dir})
	if err != nil {
		t.Fatalf("discoverTests() error = %v", err)
	}

	want := []string{
		filepath.Join(dir, "a.mojo"),
		filepath.Join(dir, "b.mojo"),
	}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("discoverTests() = %#v, want %#v", paths, want)
	}
}

func TestDiscoverTestsEmptyDirectory(t *testing.T) {
	t.Parallel()

	_, err := discoverTests([]string{t.TempDir()})
	if !errors.Is(err, errNoTests) {
		t.Fatalf("discoverTests() error = %v, want errNoTests", err)
	}
}

func TestDiscoverTestsDirectFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "direct.mojo")
	writeTestFile(t, source, "")

	paths, err := discoverTests([]string{source})
	if err != nil {
		t.Fatalf("discoverTests() error = %v", err)
	}

	want := []string{source}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("discoverTests() = %#v, want %#v", paths, want)
	}
}

func TestDiscoverTestsMultipleDirectFilesPreservesOperandOrder(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	first := filepath.Join(dir, "b.mojo")
	second := filepath.Join(dir, "a.mojo")
	writeTestFile(t, first, "")
	writeTestFile(t, second, "")

	paths, err := discoverTests([]string{first, second})
	if err != nil {
		t.Fatalf("discoverTests() error = %v", err)
	}

	want := []string{first, second}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("discoverTests() = %#v, want %#v", paths, want)
	}
}

func TestDiscoverTestsMixedDirectoryAndFileOperands(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	testDir := filepath.Join(dir, "tests")
	if err := os.Mkdir(testDir, 0o755); err != nil {
		t.Fatal(err)
	}
	direct := filepath.Join(dir, "z_direct.mojo")
	dirSecond := filepath.Join(testDir, "b.mojo")
	dirFirst := filepath.Join(testDir, "a.mojo")
	writeTestFile(t, direct, "")
	writeTestFile(t, dirSecond, "")
	writeTestFile(t, dirFirst, "")

	paths, err := discoverTests([]string{direct, testDir})
	if err != nil {
		t.Fatalf("discoverTests() error = %v", err)
	}

	want := []string{direct, dirFirst, dirSecond}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("discoverTests() = %#v, want %#v", paths, want)
	}
}

func TestDiscoverTestsRejectsDirectNonMojoFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "note.txt")
	writeTestFile(t, source, "")

	_, err := discoverTests([]string{source})
	if err == nil {
		t.Fatal("discoverTests() error = nil, want error")
	}
	if !strings.Contains(err.Error(), "must have .mojo extension") {
		t.Fatalf("discoverTests() error = %q, want extension error", err)
	}
}

func TestDiscoverTestsMultipleNoTestPaths(t *testing.T) {
	t.Parallel()

	first := t.TempDir()
	second := t.TempDir()
	writeTestFile(t, filepath.Join(first, "note.txt"), "")

	_, err := discoverTests([]string{first, second})
	if !errors.Is(err, errNoTests) {
		t.Fatalf("discoverTests() error = %v, want errNoTests", err)
	}
}

func TestRunWithFakeExecutorReportsPassCompileFailureAndRunFailure(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	pass := filepath.Join(dir, "a_pass.mojo")
	compileFail := filepath.Join(dir, "b_compile_fail.mojo")
	runFail := filepath.Join(dir, "c_run_fail.mojo")
	writeTestFile(t, pass, "")
	writeTestFile(t, compileFail, "")
	writeTestFile(t, runFail, "")

	executor := &fakeExecutor{
		compileBySource: map[string]processResult{
			pass:        successResult("compile pass\n", ""),
			compileFail: failResult("", "compile failed\n"),
			runFail:     successResult("", ""),
		},
		runBySource: map[string]processResult{
			pass:    successResult("run pass\n", ""),
			runFail: failResult("", "run failed\n"),
		},
	}

	var stdout bytes.Buffer
	err := run(
		context.Background(),
		[]string{"--no-color", "--parallel", "3", "--mojo-build-arg", "-I", "--mojo-build-arg", "src", "--mojo-build-args", "--foo bar", dir},
		&stdout,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"test",
		executor,
	)
	if err == nil {
		t.Fatal("run() error = nil, want failure")
	}

	output := stdout.String()
	for _, path := range []string{pass, compileFail, runFail} {
		if !strings.Contains(output, "=== "+path+" ===\n") {
			t.Fatalf("stdout missing complete result block for %s:\n%s", path, output)
		}
	}
	for _, want := range []string{
		"compile command: mojo build -I src --foo bar -o ",
		"compile stdout:\ncompile pass\n",
		"run output:\nrun pass\n",
		"compile stderr:\ncompile failed\n",
		"run: SKIPPED\nresult: FAIL\n",
		"run output:\nrun failed\n",
		"Summary: total=3 passed=1 failed_compile=1 failed_run=1",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}

	calls := executor.callsSnapshot()
	if len(calls) != 5 {
		t.Fatalf("executor calls = %d, want 5: %#v", len(calls), calls)
	}
	assertBuildArgsForSource(t, calls, pass, []string{"build", "-I", "src", "--foo", "bar", "-o"})
	assertBuildArgsForSource(t, calls, compileFail, []string{"build", "-I", "src", "--foo", "bar", "-o"})
	assertBuildArgsForSource(t, calls, runFail, []string{"build", "-I", "src", "--foo", "bar", "-o"})
}

func TestRunWithFakeExecutorAcceptsMultipleDirectFiles(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	first := filepath.Join(dir, "first.mojo")
	second := filepath.Join(dir, "second.mojo")
	writeTestFile(t, first, "")
	writeTestFile(t, second, "")

	executor := &fakeExecutor{
		compileBySource: map[string]processResult{
			first:  successResult("compile first\n", ""),
			second: successResult("compile second\n", ""),
		},
		runBySource: map[string]processResult{
			first:  successResult("run first\n", ""),
			second: successResult("run second\n", ""),
		},
	}

	var stdout bytes.Buffer
	err := run(
		context.Background(),
		[]string{"--no-color", "--parallel", "1", first, second},
		&stdout,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
		"test",
		executor,
	)
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"=== " + first + " ===\n",
		"=== " + second + " ===\n",
		"compile stdout:\ncompile first\n",
		"compile stdout:\ncompile second\n",
		"run output:\nrun first\n",
		"run output:\nrun second\n",
		"Summary: total=2 passed=2 failed_compile=0 failed_run=0",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}

	calls := executor.callsSnapshot()
	if len(calls) != 4 {
		t.Fatalf("executor calls = %d, want 4: %#v", len(calls), calls)
	}
	assertBuildArgsForSource(t, calls, first, []string{"build", "-o"})
	assertBuildArgsForSource(t, calls, second, []string{"build", "-o"})
}

func TestRunWithFakeMojoExecutable(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake executable script is POSIX-only")
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "sample.mojo")
	writeTestFile(t, source, "")

	binDir := filepath.Join(dir, "bin")
	if err := os.Mkdir(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "calls.log")
	mojoPath := filepath.Join(binDir, "mojo")
	script := fmt.Sprintf(`#!/bin/sh
printf 'mojo %%s\n' "$*" >> %q
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi
  prev="$arg"
done
cat > "$out" <<'EOF'
#!/bin/sh
echo fake binary ran
exit 0
EOF
chmod +x "$out"
echo fake compile stdout
echo fake compile stderr >&2
exit 0
`, logPath)
	if err := os.WriteFile(mojoPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var stdout bytes.Buffer
	err := Run(context.Background(), []string{"--no-color", "--parallel", "1", "--mojo-build-arg", "-I", "--mojo-build-arg", "src", dir}, &stdout, nil, "test")
	if err != nil {
		t.Fatalf("Run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	log := string(logBytes)
	for _, want := range []string{"mojo build -I src -o ", source} {
		if !strings.Contains(log, want) {
			t.Fatalf("fake mojo log missing %q:\n%s", want, log)
		}
	}

	output := stdout.String()
	for _, want := range []string{
		"compile command: mojo build -I src -o ",
		"compile stdout:\nfake compile stdout\n",
		"compile stderr:\nfake compile stderr\n",
		"run output:\nfake binary ran\n",
		"result: PASS\n",
		"Summary: total=1 passed=1 failed_compile=0 failed_run=0",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}
}

func TestRunSurfacesNonZeroProcessExit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake executable script is POSIX-only")
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "sample.mojo")
	writeTestFile(t, source, "")

	binDir := filepath.Join(dir, "bin")
	if err := os.Mkdir(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mojoPath := filepath.Join(binDir, "mojo")
	script := `#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi
  prev="$arg"
done
cat > "$out" <<'EOF'
#!/bin/sh
echo failing binary >&2
exit 7
EOF
chmod +x "$out"
exit 0
`
	if err := os.WriteFile(mojoPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var stdout bytes.Buffer
	err := Run(context.Background(), []string{"--no-color", dir}, &stdout, nil, "test")
	if err == nil {
		t.Fatal("Run() error = nil, want failure")
	}

	output := stdout.String()
	for _, want := range []string{
		"run: FAIL exit=7",
		"run output:\nfailing binary\n",
		"Summary: total=1 passed=0 failed_compile=0 failed_run=1",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}
}

func TestRunColorsOutputByDefault(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "pass.mojo")
	writeTestFile(t, source, "")

	var stdout bytes.Buffer
	err := run(context.Background(), []string{dir}, &stdout, nil, "test", &fakeExecutor{})
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"\x1b[36;1m=== " + source + " ===\x1b[0m",
		"compile: \x1b[32mPASS\x1b[0m",
		"run: \x1b[32mPASS\x1b[0m",
		"\x1b[1mresult:\x1b[0m \x1b[32mPASS\x1b[0m",
		"\x1b[36;1mSummary:\x1b[0m total=1 passed=1 failed_compile=0 failed_run=0",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}
}

func TestNoColorDisablesANSIOutput(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "pass.mojo"), "")

	var stdout bytes.Buffer
	err := run(context.Background(), []string{"--no-color", dir}, &stdout, nil, "test", &fakeExecutor{})
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	output := stdout.String()
	if strings.Contains(output, "\x1b[") {
		t.Fatalf("stdout contains ANSI escape codes with -no-color:\n%q", output)
	}
	if !strings.Contains(output, "result: PASS\n") {
		t.Fatalf("stdout missing plain result:\n%s", output)
	}
}

func TestRunPrintsProgressForActiveTasks(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "progress_test.mojo")
	writeTestFile(t, source, "")

	var stdout bytes.Buffer
	err := run(context.Background(), []string{"--no-color", "--parallel", "1", dir}, &stdout, nil, "test", &fakeExecutor{})
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"C progress_test.mojo, PROGRESS [0/1]",
		"R progress_test.mojo, PROGRESS [0/1]",
		"PROGRESS [1/1]",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}
}

func TestPrintProgressLiveOverwritesCurrentLine(t *testing.T) {
	t.Parallel()

	progress := newProgressTracker(10)
	progress.update(progressUpdate{path: filepath.Join("tests", "test_file3.mojo"), stage: stageCompiling})
	progress.update(progressUpdate{path: filepath.Join("tests", "test_file1.mojo"), stage: stageRunning})

	var stdout bytes.Buffer
	if err := printProgress(&stdout, progress, true); err != nil {
		t.Fatalf("printProgress() error = %v", err)
	}

	got := stdout.String()
	want := "\r\x1b[2KC test_file3.mojo, R test_file1.mojo, PROGRESS [0/10]"
	if got != want {
		t.Fatalf("live progress = %q, want %q", got, want)
	}
}

func TestRunHonorsParallelLimit(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	for i := range 8 {
		writeTestFile(t, filepath.Join(dir, fmt.Sprintf("%02d.mojo", i)), "")
	}

	executor := &parallelTrackingExecutor{delay: 5 * time.Millisecond}
	var stdout bytes.Buffer
	err := run(context.Background(), []string{"--parallel", "2", dir}, &stdout, nil, "test", executor)
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	if got, want := executor.maxSeen(), 2; got != want {
		t.Fatalf("max concurrent commands = %d, want %d", got, want)
	}
	if got, want := executor.callCount(), 16; got != want {
		t.Fatalf("command count = %d, want %d", got, want)
	}
}

func TestRunUsesFakeTTYForBinaryOnly(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "pass.mojo")
	writeTestFile(t, source, "")

	executor := &fakeExecutor{}
	var stdout bytes.Buffer
	err := run(context.Background(), []string{"--no-color", dir}, &stdout, nil, "test", executor)
	if err != nil {
		t.Fatalf("run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	calls := executor.callsSnapshot()
	if len(calls) != 2 {
		t.Fatalf("executor calls = %d, want 2: %#v", len(calls), calls)
	}
	if calls[0].fakeTTY {
		t.Fatalf("compile call fakeTTY = true, want false: %#v", calls[0])
	}
	if !calls[1].fakeTTY {
		t.Fatalf("run call fakeTTY = false, want true: %#v", calls[1])
	}
}

func TestRunOneWithASANAddsSanitizerBuildArgsAndPreload(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "pass.mojo")
	writeTestFile(t, source, "")

	executor := &fakeExecutor{}
	result := runOne(context.Background(), config{
		asan: true,
		asanRuntime: asanRuntime{
			libPath:    "/tmp/libclang_rt.asan.dylib",
			preloadVar: "DYLD_INSERT_LIBRARIES",
			buildArgs:  []string{"--external-libasan", "/tmp/libclang_rt.asan.dylib"},
		},
	}, t.TempDir(), source, executor, make(chan runEvent, 3))
	if !result.passed() {
		t.Fatalf("runOne() failed: %#v", result)
	}

	calls := executor.callsSnapshot()
	if len(calls) != 2 {
		t.Fatalf("executor calls = %d, want 2: %#v", len(calls), calls)
	}
	assertBuildArgsForSource(t, calls, source, []string{"build", "--sanitize", "address", "--external-libasan", "/tmp/libclang_rt.asan.dylib", "-o"})
	if got, want := calls[1].env, []string{"DYLD_INSERT_LIBRARIES=/tmp/libclang_rt.asan.dylib"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("run env = %#v, want %#v", got, want)
	}
}

func TestLocateASANRuntimeUsesClangResourceDirForDarwinARM64(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake clang script is POSIX-only")
	}
	t.Parallel()

	dir := t.TempDir()
	resourceDir := filepath.Join(dir, "clang-resource")
	libPath := filepath.Join(resourceDir, "lib", "darwin", "libclang_rt.asan_osx_dynamic.dylib")
	writeExecutable(t, filepath.Join(dir, "clang"), fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %q\n", resourceDir))
	if err := os.MkdirAll(filepath.Dir(libPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(libPath, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	runtime, err := locateASANRuntimeWith("darwin/arm64", filepath.Join(dir, "clang"))
	if err != nil {
		t.Fatalf("locateASANRuntimeWith() error = %v", err)
	}
	if runtime.libPath != libPath {
		t.Fatalf("libPath = %q, want %q", runtime.libPath, libPath)
	}
	if runtime.preloadVar != "DYLD_INSERT_LIBRARIES" {
		t.Fatalf("preloadVar = %q, want DYLD_INSERT_LIBRARIES", runtime.preloadVar)
	}
	if got, want := runtime.buildArgs, []string{"--external-libasan", libPath}; !reflect.DeepEqual(got, want) {
		t.Fatalf("buildArgs = %#v, want %#v", got, want)
	}
}

func TestLocateASANRuntimeUsesClangResourceDirForLinuxAMD64(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake clang script is POSIX-only")
	}
	t.Parallel()

	dir := t.TempDir()
	resourceDir := filepath.Join(dir, "clang-resource")
	firstLibPath := filepath.Join(resourceDir, "lib", "linux", "libclang_rt.asan-aarch64.so")
	secondLibPath := filepath.Join(resourceDir, "lib", "linux", "libclang_rt.asan-x86_64.so")
	writeExecutable(t, filepath.Join(dir, "clang"), fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %q\n", resourceDir))
	if err := os.MkdirAll(filepath.Dir(secondLibPath), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{secondLibPath, firstLibPath} {
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	runtime, err := locateASANRuntimeWith("linux/amd64", filepath.Join(dir, "clang"))
	if err != nil {
		t.Fatalf("locateASANRuntimeWith() error = %v", err)
	}
	if runtime.libPath != firstLibPath {
		t.Fatalf("libPath = %q, want first sorted match %q", runtime.libPath, firstLibPath)
	}
	if runtime.preloadVar != "LD_PRELOAD" {
		t.Fatalf("preloadVar = %q, want LD_PRELOAD", runtime.preloadVar)
	}
}

func TestLocateASANRuntimeReportsCompilerResourceDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake clang script is POSIX-only")
	}
	t.Parallel()

	dir := t.TempDir()
	resourceDir := filepath.Join(dir, "clang-resource")
	clangPath := filepath.Join(dir, "clang")
	writeExecutable(t, clangPath, fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %q\n", resourceDir))

	_, err := locateASANRuntimeWith("darwin/arm64", clangPath)
	if err == nil {
		t.Fatal("locateASANRuntimeWith() error = nil, want missing runtime error")
	}
	for _, want := range []string{
		"compatible AddressSanitizer runtime not found for darwin/arm64",
		"Compiler queried: " + clangPath + " --print-resource-dir",
		"Compiler resource dir: " + resourceDir,
		"Searched below: " + filepath.Join(resourceDir, "lib"),
		"pixi add compiler-rt --platform osx-arm64",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error missing %q:\n%s", want, err)
		}
	}
}

func TestRunOneWithASANHonorsSkipComment(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "skip.mojo")
	writeTestFile(t, source, "# SKIP_ASAN\n")

	executor := &fakeExecutor{}
	result := runOne(context.Background(), config{
		asan: true,
		asanRuntime: asanRuntime{
			libPath:    "/tmp/libclang_rt.asan.dylib",
			preloadVar: "DYLD_INSERT_LIBRARIES",
			buildArgs:  []string{"--external-libasan", "/tmp/libclang_rt.asan.dylib"},
		},
	}, t.TempDir(), source, executor, make(chan runEvent, 3))
	if !result.passed() {
		t.Fatalf("runOne() failed: %#v", result)
	}

	calls := executor.callsSnapshot()
	if len(calls) != 2 {
		t.Fatalf("executor calls = %d, want 2: %#v", len(calls), calls)
	}
	if contains(calls[0].args, "--sanitize") {
		t.Fatalf("build args contain ASAN sanitizer despite skip comment: %#v", calls[0].args)
	}
	if len(calls[1].env) != 0 {
		t.Fatalf("run env = %#v, want empty", calls[1].env)
	}
}

func TestRunOneWithASANDetectsReportInZeroExitOutput(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	source := filepath.Join(dir, "asan_fail.mojo")
	writeTestFile(t, source, "")

	executor := &fakeExecutor{
		runBySource: map[string]processResult{
			source: successResult("ERROR: AddressSanitizer: heap-use-after-free\n", ""),
		},
	}
	result := runOne(context.Background(), config{
		asan: true,
		asanRuntime: asanRuntime{
			libPath:    "/tmp/libclang_rt.asan.dylib",
			preloadVar: "DYLD_INSERT_LIBRARIES",
			buildArgs:  []string{"--external-libasan", "/tmp/libclang_rt.asan.dylib"},
		},
	}, t.TempDir(), source, executor, make(chan runEvent, 3))
	if !result.runFailed() {
		t.Fatalf("runOne() did not treat ASAN report as failure: %#v", result)
	}
	if result.run.err == nil || !strings.Contains(result.run.err.Error(), "AddressSanitizer") {
		t.Fatalf("run err = %v, want AddressSanitizer detection error", result.run.err)
	}
}

func TestRunBinarySeesTTYOnStdoutAndStderr(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("PTY-backed fake TTY is not supported on Windows")
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "sample.mojo")
	writeTestFile(t, source, "")

	binDir := filepath.Join(dir, "bin")
	if err := os.Mkdir(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mojoPath := filepath.Join(binDir, "mojo")
	script := `#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi
  prev="$arg"
done
cat > "$out" <<'EOF'
#!/bin/sh
if [ ! -t 1 ]; then
  echo stdout is not a tty
  exit 3
fi
if [ ! -t 2 ]; then
  echo stderr is not a tty >&2
  exit 4
fi
echo stdout tty
echo stderr tty >&2
exit 0
EOF
chmod +x "$out"
exit 0
`
	if err := os.WriteFile(mojoPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var stdout bytes.Buffer
	err := Run(context.Background(), []string{"--no-color", dir}, &stdout, nil, "test")
	if err != nil {
		t.Fatalf("Run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"run output:\nstdout tty\nstderr tty\n",
		"result: PASS\n",
		"Summary: total=1 passed=1 failed_compile=0 failed_run=0",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout missing %q:\n%s", want, output)
		}
	}
}

func TestRunReturnsContextErrorWhenCanceledBeforeWork(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "test.mojo"), "")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	var stdout bytes.Buffer
	err := Run(ctx, []string{dir}, &stdout, nil, "test")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context.Canceled", err)
	}
}

func TestFormatCommandQuotesDisplayOnly(t *testing.T) {
	t.Parallel()

	got := formatCommand([]string{"mojo", "build", "-Dname=value with spaces", "-Dquote=it's", "-o", "/tmp/out", "test.mojo"})
	want := "mojo build '-Dname=value with spaces' '-Dquote=it'\\''s' -o /tmp/out test.mojo"
	if got != want {
		t.Fatalf("formatCommand() = %q, want %q", got, want)
	}
}

func TestBinaryPathForUsesHashToAvoidCollisions(t *testing.T) {
	t.Parallel()

	artifactDir := t.TempDir()
	first := binaryPathFor(artifactDir, filepath.Join("one", "same.mojo"))
	second := binaryPathFor(artifactDir, filepath.Join("two", "same.mojo"))
	if first == second {
		t.Fatalf("binary paths collided: %q", first)
	}
	if filepath.Dir(first) != artifactDir || filepath.Dir(second) != artifactDir {
		t.Fatalf("binary paths are not in artifact dir: %q %q", first, second)
	}
}

func TestArtifactsAreRemovedByDefault(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake executable script is POSIX-only")
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "sample.mojo")
	writeTestFile(t, source, "")
	logPath := filepath.Join(dir, "outputs.log")
	binDir := installArtifactLoggingMojo(t, dir, logPath)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var stdout bytes.Buffer
	err := Run(context.Background(), []string{dir}, &stdout, nil, "test")
	if err != nil {
		t.Fatalf("Run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	outputPath := readFirstLine(t, logPath)
	artifactDir := filepath.Dir(outputPath)
	if _, err := os.Stat(artifactDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("artifact dir still exists after run: stat err = %v, path = %s", err, artifactDir)
	}
	if strings.Contains(stdout.String(), "artifacts: ") {
		t.Fatalf("stdout printed artifact path without -keep-artifacts:\n%s", stdout.String())
	}
}

func TestKeepArtifactsPrintsAndRetainsArtifactDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake executable script is POSIX-only")
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "sample.mojo")
	writeTestFile(t, source, "")
	logPath := filepath.Join(dir, "outputs.log")
	binDir := installArtifactLoggingMojo(t, dir, logPath)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var stdout bytes.Buffer
	err := Run(context.Background(), []string{"--keep-artifacts", dir}, &stdout, nil, "test")
	if err != nil {
		t.Fatalf("Run() error = %v\nstdout:\n%s", err, stdout.String())
	}

	outputPath := readFirstLine(t, logPath)
	artifactDir := filepath.Dir(outputPath)
	if _, err := os.Stat(outputPath); err != nil {
		t.Fatalf("compiled artifact was not retained: %v", err)
	}
	if !strings.Contains(stdout.String(), "artifacts: "+artifactDir+"\n") {
		t.Fatalf("stdout missing retained artifact dir %q:\n%s", artifactDir, stdout.String())
	}
}

type fakeExecutor struct {
	mu              sync.Mutex
	calls           []fakeCall
	binaryToSource  map[string]string
	compileBySource map[string]processResult
	runBySource     map[string]processResult
}

type fakeCall struct {
	name    string
	args    []string
	fakeTTY bool
	env     []string
}

func (f *fakeExecutor) Run(_ context.Context, opts commandOptions, name string, args ...string) processResult {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.calls = append(f.calls, fakeCall{name: name, args: append([]string(nil), args...), fakeTTY: opts.fakeTTY, env: append([]string(nil), opts.env...)})

	if name == "mojo" {
		source := args[len(args)-1]
		output := ""
		for i := 0; i < len(args)-1; i++ {
			if args[i] == "-o" {
				output = args[i+1]
				break
			}
		}
		if f.binaryToSource == nil {
			f.binaryToSource = make(map[string]string)
		}
		f.binaryToSource[output] = source
		if result, ok := f.compileBySource[source]; ok {
			return result
		}
		return successResult("", "")
	}

	source := f.binaryToSource[name]
	if result, ok := f.runBySource[source]; ok {
		result = fakeCombinedResult(result, opts.fakeTTY)
		return result
	}
	result := successResult("", "")
	return fakeCombinedResult(result, opts.fakeTTY)
}

func (f *fakeExecutor) callsSnapshot() []fakeCall {
	f.mu.Lock()
	defer f.mu.Unlock()

	calls := make([]fakeCall, len(f.calls))
	copy(calls, f.calls)
	return calls
}

func successResult(stdout, stderr string) processResult {
	return processResult{stdout: stdout, stderr: stderr, exitCode: 0, duration: time.Millisecond}
}

func failResult(stdout, stderr string) processResult {
	return processResult{stdout: stdout, stderr: stderr, exitCode: 1, duration: time.Millisecond, err: errors.New("exit status 1")}
}

func fakeCombinedResult(result processResult, combined bool) processResult {
	if !combined {
		return result
	}
	result.stdout += result.stderr
	result.stderr = ""
	result.combined = true
	return result
}

func assertBuildArgsForSource(t *testing.T, calls []fakeCall, source string, prefix []string) {
	t.Helper()

	for _, call := range calls {
		if call.name != "mojo" || len(call.args) == 0 || call.args[len(call.args)-1] != source {
			continue
		}
		if len(call.args) < len(prefix)+2 {
			t.Fatalf("build args for %s too short: %#v", source, call.args)
		}
		if !reflect.DeepEqual(call.args[:len(prefix)], prefix) {
			t.Fatalf("build args prefix for %s = %#v, want %#v", source, call.args[:len(prefix)], prefix)
		}
		return
	}

	t.Fatalf("missing build call for %s in %#v", source, calls)
}

func contains(values []string, needle string) bool {
	return slices.Contains(values, needle)
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()

	writeFile(t, path, content, 0o644)
}

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()

	writeFile(t, path, content, 0o755)
}

func writeFile(t *testing.T, path, content string, perm os.FileMode) {
	t.Helper()

	if err := os.WriteFile(path, []byte(content), perm); err != nil {
		t.Fatal(err)
	}
}

type parallelTrackingExecutor struct {
	mu     sync.Mutex
	active int
	max    int
	calls  int
	delay  time.Duration
}

func (e *parallelTrackingExecutor) Run(_ context.Context, _ commandOptions, _ string, _ ...string) processResult {
	e.mu.Lock()
	e.active++
	e.calls++
	if e.active > e.max {
		e.max = e.active
	}
	e.mu.Unlock()

	time.Sleep(e.delay)

	e.mu.Lock()
	e.active--
	e.mu.Unlock()

	return successResult("", "")
}

func (e *parallelTrackingExecutor) maxSeen() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.max
}

func (e *parallelTrackingExecutor) callCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.calls
}

func installArtifactLoggingMojo(t *testing.T, dir, logPath string) string {
	t.Helper()

	binDir := filepath.Join(dir, "bin")
	if err := os.Mkdir(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	mojoPath := filepath.Join(binDir, "mojo")
	script := fmt.Sprintf(`#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
  fi
  prev="$arg"
done
printf '%%s\n' "$out" >> %q
cat > "$out" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$out"
exit 0
`, logPath)
	if err := os.WriteFile(mojoPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return binDir
}

func readFirstLine(t *testing.T, path string) string {
	t.Helper()

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	line, _, _ := strings.Cut(string(content), "\n")
	if line == "" {
		t.Fatalf("%s was empty", path)
	}
	return line
}
