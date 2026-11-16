"""Tests for the `posix` abstractions over libc: env, fd, pty, spawn, and
signals.
"""

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.posix import libc
from mogo_tester.posix.cffi import addr
from mogo_tester.posix.env import Environment
from mogo_tester.posix.fd import PollSet, close_fd, make_pipe, read_fd
from mogo_tester.posix.pty import open_pty
from mogo_tester.posix.signals import InterruptGuard
from mogo_tester.posix.spawn import is_executable, look_path, signal_name


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


def test_interrupt_guard_observes_sigint_once() raises:
    var guard = InterruptGuard()
    assert_false(guard.interrupted())
    assert_equal(libc.kill(libc.getpid(), libc.SIGINT), 0)
    assert_true(guard.interrupted())
    # Later SIGINTs are ignored instead of terminating the process.
    assert_equal(libc.kill(libc.getpid(), libc.SIGINT), 0)
    assert_true(guard.interrupted())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
