package app

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type printOutcome struct {
	summary runSummary
	err     error
}

type testStage int

const (
	stageDone testStage = iota
	stageCompiling
	stageRunning
)

type runEvent struct {
	progress progressUpdate
	result   *fileResult
}

type progressUpdate struct {
	path  string
	stage testStage
}

func printEvents(stdout io.Writer, events <-chan runEvent, start time.Time, colorEnabled bool, total int, done chan<- printOutcome) {
	summary := runSummary{}
	var err error
	colors := outputColors{enabled: colorEnabled}
	progress := newProgressTracker(total)
	liveProgress := isTerminal(stdout)
	progressVisible := false

	for event := range events {
		if event.progress.path != "" {
			progress.update(event.progress)
			if printErr := printProgress(stdout, progress, liveProgress); printErr != nil && err == nil {
				err = printErr
			}
			progressVisible = liveProgress
			continue
		}
		if event.result == nil {
			continue
		}

		result := *event.result
		summary.total++
		switch {
		case result.passed():
			summary.passed++
		case result.compileFailed():
			summary.failedCompile++
		case result.runFailed():
			summary.failedRun++
		}

		if liveProgress && progressVisible {
			if printErr := clearProgress(stdout); printErr != nil && err == nil {
				err = printErr
			}
			progressVisible = false
		}
		if printErr := printResultBlock(stdout, result, colors); printErr != nil && err == nil {
			err = printErr
		}
		if liveProgress && progress.completed < progress.total {
			if printErr := printProgress(stdout, progress, true); printErr != nil && err == nil {
				err = printErr
			}
			progressVisible = true
		}
	}

	if liveProgress && progressVisible {
		if printErr := clearProgress(stdout); printErr != nil && err == nil {
			err = printErr
		}
	}
	summary.elapsed = time.Since(start)
	if printErr := printSummary(stdout, summary, colors); printErr != nil && err == nil {
		err = printErr
	}

	done <- printOutcome{summary: summary, err: err}
}

type progressTracker struct {
	total     int
	completed int
	stages    map[string]testStage
}

func newProgressTracker(total int) progressTracker {
	return progressTracker{
		total:  total,
		stages: make(map[string]testStage),
	}
}

func (p *progressTracker) update(update progressUpdate) {
	if update.stage == stageDone {
		if _, ok := p.stages[update.path]; ok {
			delete(p.stages, update.path)
			p.completed++
		}
		return
	}
	p.stages[update.path] = update.stage
}

func printProgress(w io.Writer, progress progressTracker, live bool) error {
	line := formatProgress(progress)
	if live {
		_, err := fmt.Fprintf(w, "\r\x1b[2K%s", line)
		return err
	}
	_, err := fmt.Fprintln(w, line)
	return err
}

func clearProgress(w io.Writer) error {
	_, err := fmt.Fprint(w, "\r\x1b[2K")
	return err
}

func formatProgress(progress progressTracker) string {
	parts := make([]string, 0, 3)
	if compiling := progress.pathsFor(stageCompiling); len(compiling) > 0 {
		parts = append(parts, "C "+strings.Join(compiling, ", "))
	}
	if running := progress.pathsFor(stageRunning); len(running) > 0 {
		parts = append(parts, "R "+strings.Join(running, ", "))
	}
	parts = append(parts, fmt.Sprintf("PROGRESS [%d/%d]", progress.completed, progress.total))

	return strings.Join(parts, ", ")
}

func isTerminal(w io.Writer) bool {
	file, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

func (p progressTracker) pathsFor(stage testStage) []string {
	var paths []string
	for path, current := range p.stages {
		if current == stage {
			paths = append(paths, filepath.Base(path))
		}
	}
	sort.Strings(paths)
	return paths
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
