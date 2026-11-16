"""Tests for running child processes and capturing their output."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.posix import libc
from mogo_tester.posix.cffi import vp
from mogo_tester.posix.env import Environment
from mogo_tester.posix.spawn import kill_group
from mogo_tester.process.child import Child
from mogo_tester.process.result import CommandOptions
from mogo_tester.process.run import poll_children, run_command


def test_pipes_capture_stdout_stderr_and_exit_status() raises:
    var r = run_command(
        ["sh", "-c", "echo out; echo err >&2; exit 3"], CommandOptions.plain()
    )
    assert_equal(r.stdout, "out\n")
    assert_equal(r.stderr, "err\n")
    assert_false(r.combined)
    assert_equal(r.exit_code, 3)
    assert_equal(r.error, "exit status 3")


def test_tty_combines_output_and_is_a_terminal() raises:
    var r = run_command(
        [
            "sh",
            "-c",
            (
                "[ -t 1 ] && echo stdout-tty; [ -t 2 ] && echo stderr-tty >&2;"
                " [ -t 0 ] || echo stdin-not-tty"
            ),
        ],
        CommandOptions.tty(),
    )
    assert_true(r.combined)
    assert_equal(r.stdout, "stdout-tty\nstderr-tty\nstdin-not-tty\n")
    assert_true(r.succeeded())


def test_signal_and_missing_executable() raises:
    var killed = run_command(["sh", "-c", "kill -9 $$"], CommandOptions.tty())
    assert_equal(killed.exit_code, -1)
    assert_equal(killed.error, "signal: killed")
    var missing = run_command(["mogo-no-such-binary"], CommandOptions.plain())
    assert_equal(missing.exit_code, -1)
    assert_equal(
        missing.error,
        'exec: "mogo-no-such-binary": executable file not found in $PATH',
    )


def test_children_start_with_default_sigint() raises:
    # A child must not inherit an ignored SIGINT from the parent.
    var r = run_command(
        ["sh", "-c", "kill -INT $$; echo survived"], CommandOptions.plain()
    )
    assert_equal(r.error, "signal: interrupt")
    assert_equal(r.stdout, "")


def finish_with_background_descendant(options: CommandOptions) raises:
    var children = List[Child]()
    children.append(
        Child(["sh", "-c", "echo before; sleep 30 & exit 0"], options)
    )
    var polls = 0
    while poll_children(children, 100):
        polls += 1
        if polls >= 50:
            kill_group(children[0].pid, libc.SIGKILL)
            raise Error(
                "child stayed active while a descendant held its output"
            )
    kill_group(children[0].pid, libc.SIGKILL)  # Clean up the background sleep.
    var r = children[0].result()
    assert_true(r.succeeded())
    assert_equal(r.stdout, "before\n")


def test_exited_child_finishes_despite_background_descendant_tty() raises:
    finish_with_background_descendant(CommandOptions.tty())


def test_exited_child_finishes_despite_background_descendant_pipes() raises:
    finish_with_background_descendant(CommandOptions.plain())


def test_try_reap_reports_exit() raises:
    var child = Child(["sh", "-c", "exit 0"], CommandOptions.plain())
    var reaped = False
    for _ in range(500):
        if child.try_reap():
            reaped = True
            break
        _ = libc.poll(vp(0), 0, 10)
    assert_true(reaped)


def test_environment_overrides_reach_child() raises:
    var env = Environment()
    env.set("MOGO_PROBE", "one two")
    env.set("HOME", "/nowhere")
    var r = run_command(
        ["sh", "-c", 'echo "$MOGO_PROBE|$HOME"'], CommandOptions(False, env^)
    )
    assert_equal(r.stdout, "one two|/nowhere\n")


def test_large_output_is_drained() raises:
    var r = run_command(
        ["sh", "-c", "yes x | head -c 300000"], CommandOptions.tty()
    )
    assert_equal(r.stdout.byte_length(), 300000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
