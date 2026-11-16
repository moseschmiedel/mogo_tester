"""Progress, per-file result blocks, and the final summary."""

from .paths import base_name
from .process import ProcessResult


struct Output(Movable):
    """Destination for report text: stdout, or an in-memory buffer."""

    var capture: Bool
    var buffer: String

    def __init__(out self, capture: Bool = False):
        self.capture = capture
        self.buffer = ""

    def write(mut self, text: String):
        if self.capture:
            self.buffer += text
        else:
            print(text, end="", flush=True)


@fieldwise_init
struct Colors(Copyable, Movable):
    """ANSI styling that degrades to plain text when disabled."""

    var enabled: Bool

    def wrap(self, code: String, value: String) -> String:
        if not self.enabled:
            return value
        return code + value + "\x1b[0m"

    def header(self, value: String) -> String:
        return self.wrap("\x1b[36;1m", value)

    def summary(self, value: String) -> String:
        return self.wrap("\x1b[36;1m", value)

    def label(self, value: String) -> String:
        return self.wrap("\x1b[1m", value)

    def pass_(self, value: String) -> String:
        return self.wrap("\x1b[32m", value)

    def fail(self, value: String) -> String:
        return self.wrap("\x1b[31m", value)

    def skip(self, value: String) -> String:
        return self.wrap("\x1b[33m", value)

    def dim(self, value: String) -> String:
        return self.wrap("\x1b[2m", value)


@fieldwise_init
struct FileResult(Copyable, Movable):
    """Compile and run outcome for one test source file."""

    var path: String
    var compile_cmd: List[String]
    var compile: ProcessResult
    var run: ProcessResult
    var did_run: Bool
    var binary_path: String

    def passed(self) -> Bool:
        return (
            self.compile.succeeded() and self.did_run and self.run.succeeded()
        )

    def compile_failed(self) -> Bool:
        return not self.compile.succeeded()

    def run_failed(self) -> Bool:
        return self.compile.succeeded() and (
            not self.did_run or not self.run.succeeded()
        )


@fieldwise_init
struct RunSummary(Copyable, Movable):
    """Aggregate counters for a whole run."""

    var total: Int
    var passed: Int
    var failed_compile: Int
    var failed_run: Int
    var elapsed_ns: Int

    def __init__(out self):
        self = Self(0, 0, 0, 0, 0)

    def failed(self) -> Bool:
        return self.failed_compile > 0 or self.failed_run > 0

    def add(mut self, result: FileResult):
        self.total += 1
        if result.passed():
            self.passed += 1
        elif result.compile_failed():
            self.failed_compile += 1
        elif result.run_failed():
            self.failed_run += 1


comptime STAGE_DONE = 0
comptime STAGE_COMPILING = 1
comptime STAGE_RUNNING = 2


struct ProgressTracker(Movable):
    """Active stage per file plus the completed/total counter."""

    var total: Int
    var completed: Int
    var paths: List[String]
    var stages: List[Int]

    def __init__(out self, total: Int):
        self.total = total
        self.completed = 0
        self.paths = List[String]()
        self.stages = List[Int]()

    def update(mut self, path: String, stage: Int):
        """Records the latest stage for path; leaving the active set counts
        the file as completed."""
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                if stage == STAGE_DONE:
                    _ = self.paths.pop(i)
                    _ = self.stages.pop(i)
                    self.completed += 1
                else:
                    self.stages[i] = stage
                return
        if stage != STAGE_DONE:
            self.paths.append(path)
            self.stages.append(stage)

    def paths_for(self, stage: Int) -> List[String]:
        """Returns sorted basenames of files currently in stage."""
        var result = List[String]()
        for i in range(len(self.paths)):
            if self.stages[i] == stage:
                result.append(base_name(self.paths[i]))
        sort(Span(result))
        return result^


def format_progress(progress: ProgressTracker) -> String:
    """Renders active compile and run stages and the completed/total count."""
    var parts = List[String]()
    var compiling = progress.paths_for(STAGE_COMPILING)
    if len(compiling) > 0:
        parts.append("C " + ", ".join(compiling))
    var running = progress.paths_for(STAGE_RUNNING)
    if len(running) > 0:
        parts.append("R " + ", ".join(running))
    parts.append(
        String("PROGRESS [", progress.completed, "/", progress.total, "]")
    )
    return ", ".join(parts)


def print_progress(mut out: Output, progress: ProgressTracker, live: Bool):
    """Writes an in-place terminal progress line, or a plain line when the
    output is not a terminal."""
    var line = format_progress(progress)
    if live:
        out.write("\r\x1b[2K" + line)
    else:
        out.write(line + "\n")


def clear_progress(mut out: Output):
    """Erases the current terminal progress line."""
    out.write("\r\x1b[2K")


def print_result_block(mut out: Output, result: FileResult, colors: Colors):
    """Writes the compile command, process output, and PASS/FAIL status."""
    out.write(colors.header("=== " + result.path + " ===") + "\n")
    out.write(
        colors.label("compile command:")
        + " "
        + colors.dim(format_command(result.compile_cmd))
        + "\n"
    )
    print_process(out, "compile", result.compile, colors)
    if result.did_run:
        print_process(out, "run", result.run, colors)
    else:
        out.write("run: " + colors.skip("SKIPPED") + "\n")
    var status = colors.pass_("PASS") if result.passed() else colors.fail(
        "FAIL"
    )
    out.write(colors.label("result:") + " " + status + "\n\n")


def print_precompile_block(
    mut out: Output,
    path: String,
    command: List[String],
    result: ProcessResult,
    colors: Colors,
):
    """Writes the command and captured output for one precompiled package."""
    out.write(colors.header("=== precompile " + path + " ===") + "\n")
    out.write(
        colors.label("precompile command:")
        + " "
        + colors.dim(format_command(command))
        + "\n"
    )
    print_process(out, "precompile", result, colors)
    out.write("\n")


def print_process(
    mut out: Output, label: String, result: ProcessResult, colors: Colors
):
    """Writes status and captured output for one process."""
    var status = colors.pass_("PASS") if result.succeeded() else colors.fail(
        "FAIL"
    )
    out.write(
        String(
            label,
            ": ",
            status,
            " exit=",
            result.exit_code,
            " duration=",
            format_duration(result.duration_ns),
            "\n",
        )
    )
    if result.combined:
        print_captured(
            out, label + " output", combined_output_with_error(result)
        )
        return
    print_captured(out, label + " stdout", result.stdout)
    print_captured(out, label + " stderr", stderr_with_error(result))


def print_captured(mut out: Output, label: String, value: String):
    """Writes a labeled output section, adding a missing trailing newline."""
    out.write(label + ":\n")
    if value != "":
        out.write(value)
        if not value.endswith("\n"):
            out.write("\n")


def print_summary(mut out: Output, summary: RunSummary, colors: Colors):
    """Writes the final aggregate counters."""
    out.write(
        String(
            colors.summary("Summary:"),
            " total=",
            summary.total,
            " passed=",
            summary.passed,
            " failed_compile=",
            summary.failed_compile,
            " failed_run=",
            summary.failed_run,
            " elapsed=",
            format_duration(summary.elapsed_ns),
            "\n",
        )
    )


def format_command(args: List[String]) -> String:
    """Renders argv for display; execution never goes through a shell."""
    var quoted = List[String](capacity=len(args))
    for arg in args:
        quoted.append(quote_arg(arg))
    return " ".join(quoted)


def quote_arg(arg: String) -> String:
    """Applies POSIX single-quote escaping when arg needs it."""
    if arg == "":
        return "''"
    comptime special = "'\"\\$&;()<>|*?[]{}!\n\t"
    var needs_quotes = False
    for cp in arg.codepoints():
        var value = Int(cp)
        if value <= 0x20 or (value < 0x80 and String(cp) in special):
            needs_quotes = True
            break
    if not needs_quotes:
        return arg
    return "'" + arg.replace("'", "'\\''") + "'"


def stderr_with_error(result: ProcessResult) -> String:
    """Appends the execution error to stderr when the process failed."""
    if result.error == "":
        return result.stderr
    if result.stderr == "":
        return result.error
    if result.stderr.endswith("\n"):
        return result.stderr + result.error
    return result.stderr + "\n" + result.error


def combined_output_with_error(result: ProcessResult) -> String:
    """Returns PTY output, or the execution error if there was no output."""
    if result.error == "" or result.stdout != "":
        return result.stdout
    return result.error


def _frac(value: Int, precision: Int) -> Tuple[String, Int]:
    """Formats the low `precision` decimal digits of value as a fraction
    without trailing zeros; returns the text and value with them removed."""
    var v = value
    var digits = String("")
    var printing = False
    for _ in range(precision):
        var digit = v % 10
        printing = printing or digit != 0
        if printing:
            digits = String(digit) + digits
        v //= 10
    if printing:
        digits = "." + digits
    return (digits^, v)


def format_duration(ns: Int) -> String:
    """Formats nanoseconds like Go's time.Duration.String, e.g. 1.5s,
    12.345ms, 2m3.5s."""
    if ns == 0:
        return "0s"
    var negative = ns < 0
    var u = -ns if negative else ns
    var sign = "-" if negative else ""
    if u < 1_000_000_000:
        if u < 1000:
            return String(sign, u, "ns")
        var unit: String
        var precision: Int
        if u < 1_000_000:
            unit = "µs"
            precision = 3
        else:
            unit = "ms"
            precision = 6
        var parts = _frac(u, precision)
        return String(sign, parts[1], parts[0], unit)

    var parts = _frac(u, 9)
    var seconds = parts[1]
    var text = String(seconds % 60, parts[0], "s")
    var minutes = seconds // 60
    if minutes > 0:
        text = String(minutes % 60, "m") + text
        var hours = minutes // 60
        if hours > 0:
            text = String(hours, "h") + text
    return sign + text
