"""Result blocks for compiled files and precompiled packages, and the summary line."""

from std.pathlib import Path

from ..process.result import ProcessResult
from .format import (
    combined_output_with_error,
    format_command,
    format_duration,
    stderr_with_error,
)
from .output import Colors, Output
from .results import FileResult, RunSummary


def print_result_block(mut out: Output, result: FileResult, colors: Colors):
    """Writes the compile command, process output, and PASS/FAIL status."""
    out.write(colors.header(String("=== ", result.path, " ===")) + "\n")
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


def print_skipped(mut out: Output, path: Path, colors: Colors):
    """Writes the line for a file excluded from the run."""
    out.write(String(colors.skip("SKIP"), " ", path, "\n"))


def print_precompile_block(
    mut out: Output,
    path: Path,
    command: List[String],
    result: ProcessResult,
    colors: Colors,
):
    """Writes the command and captured output for one precompiled package."""
    out.write(colors.header(String("=== precompile ", path, " ===")) + "\n")
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
            " skipped=",
            summary.skipped,
            "\n",
        )
    )
