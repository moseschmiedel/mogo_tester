from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.process import ProcessResult
from mogo_tester.report import (
    Colors,
    FileResult,
    Output,
    ProgressTracker,
    RunSummary,
    STAGE_COMPILING,
    STAGE_DONE,
    STAGE_RUNNING,
    format_command,
    format_duration,
    format_progress,
    print_progress,
    print_result_block,
    print_summary,
)


def result(
    stdout: String,
    stderr: String,
    combined: Bool,
    exit_code: Int,
    error: String,
) -> ProcessResult:
    return ProcessResult(stdout, stderr, combined, exit_code, 1_500_000, error)


def test_format_command_quotes_display_only() raises:
    assert_equal(
        format_command(
            ["mojo", "build", "-I", "path with spaces", "it's", "", "a$b"]
        ),
        "mojo build -I 'path with spaces' 'it'\\''s' '' 'a$b'",
    )


def test_format_duration_matches_go() raises:
    assert_equal(format_duration(0), "0s")
    assert_equal(format_duration(999), "999ns")
    assert_equal(format_duration(1_500), "1.5µs")
    assert_equal(format_duration(12_345_678), "12.345678ms")
    assert_equal(format_duration(1_000_000_000), "1s")
    assert_equal(format_duration(1_230_000_000), "1.23s")
    assert_equal(format_duration(123_500_000_000), "2m3.5s")
    assert_equal(format_duration(3_723_000_000_000), "1h2m3s")


def test_progress_tracks_active_stages() raises:
    var progress = ProgressTracker(3)
    progress.update("t/b.mojo", STAGE_COMPILING)
    progress.update("t/a.mojo", STAGE_COMPILING)
    progress.update("t/c.mojo", STAGE_COMPILING)
    progress.update("t/c.mojo", STAGE_RUNNING)
    assert_equal(
        format_progress(progress), "C a.mojo, b.mojo, R c.mojo, PROGRESS [0/3]"
    )
    progress.update("t/c.mojo", STAGE_DONE)
    progress.update("t/c.mojo", STAGE_DONE)
    assert_equal(format_progress(progress), "C a.mojo, b.mojo, PROGRESS [1/3]")


def test_print_progress_live_overwrites_current_line() raises:
    var progress = ProgressTracker(1)
    var out = Output(capture=True)
    print_progress(out, progress, True)
    print_progress(out, progress, False)
    assert_equal(out.buffer, "\r\x1b[2KPROGRESS [0/1]PROGRESS [0/1]\n")


def test_result_block_for_compile_failure_without_color() raises:
    var file = FileResult(
        "t/a.mojo",
        ["mojo", "build", "-o", "out", "t/a.mojo"],
        result("", "error: bad", False, 1, "exit status 1"),
        ProcessResult.empty(),
        False,
        "out",
    )
    var out = Output(capture=True)
    print_result_block(out, file, Colors(False))
    assert_equal(
        out.buffer,
        "=== t/a.mojo ===\n"
        + "compile command: mojo build -o out t/a.mojo\n"
        + "compile: FAIL exit=1 duration=1.5ms\n"
        + "compile stdout:\n"
        + "compile stderr:\n"
        + "error: bad\nexit status 1\n"
        + "run: SKIPPED\n"
        + "result: FAIL\n\n",
    )


def test_result_block_for_pass_with_color() raises:
    var file = FileResult(
        "t/a.mojo",
        ["mojo", "build", "t/a.mojo"],
        result("", "", False, 0, ""),
        result("ok", "", True, 0, ""),
        True,
        "out",
    )
    var out = Output(capture=True)
    print_result_block(out, file, Colors(True))
    assert_true("\x1b[36;1m=== t/a.mojo ===\x1b[0m" in out.buffer)
    assert_true(
        "run: \x1b[32mPASS\x1b[0m exit=0 duration=1.5ms\nrun output:\nok\n"
        in out.buffer
    )
    assert_true(
        out.buffer.endswith("\x1b[1mresult:\x1b[0m \x1b[32mPASS\x1b[0m\n\n")
    )


def test_combined_output_falls_back_to_error() raises:
    var file = FileResult(
        "t/a.mojo",
        ["mojo"],
        result("", "", False, 0, ""),
        result("", "", True, -1, "signal: killed"),
        True,
        "out",
    )
    var out = Output(capture=True)
    print_result_block(out, file, Colors(False))
    assert_true("run output:\nsignal: killed\n" in out.buffer)
    assert_false(file.passed())
    assert_true(file.run_failed())


def test_summary_counts() raises:
    var summary = RunSummary()
    summary.total = 3
    summary.passed = 1
    summary.failed_compile = 1
    summary.failed_run = 1
    summary.elapsed_ns = 1_230_000_000
    var out = Output(capture=True)
    print_summary(out, summary, Colors(False))
    assert_equal(
        out.buffer,
        (
            "Summary: total=3 passed=1 failed_compile=1 failed_run=1"
            " elapsed=1.23s\n"
        ),
    )
    assert_true(summary.failed())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
