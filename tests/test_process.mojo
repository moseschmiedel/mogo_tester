"""Tests for process execution and the modules it builds on: fd, pty,
spawn, env, and signals."""

from std.ffi import c_int
from std.pathlib import Path
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from mogo_tester import libc
from mogo_tester.cffi import addr, vp
from mogo_tester.env import Environment
from mogo_tester.fd import PollSet, close_fd, make_pipe, read_fd
from mogo_tester.process import (
    Child,
    CommandOptions,
    poll_children,
    run_command,
)
from mogo_tester.pty import open_pty
from mogo_tester.signals import InterruptGuard
from mogo_tester.spawn import (
    is_executable,
    kill_group,
    look_path,
    signal_name,
)


# ===-----------------------------------------------------------------------===#
# env
# ===-----------------------------------------------------------------------===#


def test_environment_set_get_unset_keeps_order() raises:
    var env = Environment()
    env.set("B", "1")
    env.set("A", "2")
    env.set("B", "3")
    assert_equal(env.entries(), ["B=3", "A=2"])
    assert_equal(env.get("A").value(), "2")
    assert_false(Bool(env.get("C")))
    env.unset("B")
    assert_false("B" in env)
    assert_equal(len(env), 1)


def test_environment_entries_with_equals_in_value() raises:
    var env = Environment()
    env.set_entry("OPTS=-a=b")
    env.set_entry("EMPTY")
    assert_equal(env.get("OPTS").value(), "-a=b")
    assert_equal(env.get("EMPTY").value(), "")


def test_environment_update_overrides() raises:
    var base = Environment()
    base.set("HOME", "/home/x")
    base.set("KEEP", "yes")
    var overrides = Environment()
    overrides.set("HOME", "/nowhere")
    overrides.set("NEW", "1")
    base.update(overrides)
    assert_equal(base.entries(), ["HOME=/nowhere", "KEEP=yes", "NEW=1"])


def test_environment_current_reads_process_environment() raises:
    var env = Environment.current()
    assert_true(len(env) > 0)
    assert_true("PATH" in env)


# ===-----------------------------------------------------------------------===#
# fd, pty
# ===-----------------------------------------------------------------------===#


def test_pipe_poll_and_read() raises:
    var fds = make_pipe()
    var poll_set = PollSet([fds[0]])
    assert_equal(poll_set.wait(0), 0)
    var payload = List[UInt8](String("ping").as_bytes())
    assert_equal(libc.write(fds[1], addr(payload), len(payload)), 4)
    assert_equal(poll_set.wait(1000), 1)
    assert_true(poll_set.ready(0))
    var buf = List[UInt8](length=16, fill=0)
    assert_equal(read_fd(fds[0], buf), 4)
    close_fd(fds[1])
    assert_equal(read_fd(fds[0], buf), 0)
    close_fd(fds[0])


def test_pipe_is_close_on_exec() raises:
    var fds = make_pipe()
    for fd in [fds[0], fds[1]]:
        var flags = libc.fcntl(fd, libc.F_GETFD, 0)
        assert_equal(flags & libc.FD_CLOEXEC, libc.FD_CLOEXEC)
        close_fd(fd)


def test_read_fd_reports_negated_errno() raises:
    var buf = List[UInt8](length=4, fill=0)
    assert_equal(read_fd(-1, buf), -Int(libc.EBADF))


def test_open_pty_pair_round_trip() raises:
    var pair = open_pty()
    var payload = List[UInt8](String("tty\n").as_bytes())
    assert_equal(libc.write(pair[1], addr(payload), len(payload)), 4)
    var poll_set = PollSet([pair[0]])
    assert_equal(poll_set.wait(1000), 1)
    var buf = List[UInt8](length=16, fill=0)
    assert_true(read_fd(pair[0], buf) > 0)
    close_fd(pair[1])
    close_fd(pair[0])


# ===-----------------------------------------------------------------------===#
# spawn
# ===-----------------------------------------------------------------------===#


def test_look_path() raises:
    var sh = look_path("sh")
    assert_true(sh.name() == "sh")
    assert_true(is_executable(sh))
    assert_equal(look_path("./relative/tool"), Path("./relative/tool"))
    try:
        _ = look_path("mogo-no-such-binary")
    except e:
        assert_equal(
            String(e),
            'exec: "mogo-no-such-binary": executable file not found in $PATH',
        )
        return
    raise Error("expected lookup failure")


def test_is_executable_rejects_directories_and_plain_files() raises:
    assert_false(is_executable(Path("/")))
    assert_false(is_executable(Path("/etc/hosts")))
    assert_false(is_executable(Path("/nonexistent")))


def test_signal_name() raises:
    assert_equal(signal_name(9), "killed")
    assert_equal(signal_name(11), "segmentation fault")
    assert_equal(signal_name(99), "signal 99")


# ===-----------------------------------------------------------------------===#
# signals
# ===-----------------------------------------------------------------------===#


def test_interrupt_guard_observes_sigint_once() raises:
    var guard = InterruptGuard()
    assert_false(guard.interrupted())
    assert_equal(libc.kill(libc.getpid(), libc.SIGINT), 0)
    assert_true(guard.interrupted())
    # Later SIGINTs are ignored instead of terminating the process.
    assert_equal(libc.kill(libc.getpid(), libc.SIGINT), 0)
    assert_true(guard.interrupted())


# ===-----------------------------------------------------------------------===#
# process
# ===-----------------------------------------------------------------------===#


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
