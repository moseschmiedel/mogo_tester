"""Tests for the direct libc bindings in `mogo_tester.libc`.

Each test exercises the bindings with the C calling convention: raw
buffers, return codes, and errno.
"""

from std.ffi import c_int, c_short
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mogo_tester.posix import libc
from mogo_tester.posix.cffi import (
    CStringArray,
    addr,
    c_string_at,
    cstr,
    load,
    store,
    vp,
)


def test_pipe_write_read_close() raises:
    var fds = List[c_int](length=2, fill=-1)
    assert_equal(libc.pipe(addr(fds)), 0)
    var message = String("hello")
    assert_equal(libc.write(fds[1], cstr(message), 5), 5)
    var buf = List[UInt8](length=16, fill=0)
    assert_equal(libc.read(fds[0], addr(buf), 16), 5)
    assert_equal(String(unsafe_from_utf8=Span(buf)[0:5]), "hello")
    assert_equal(libc.close(fds[1]), 0)
    assert_equal(libc.read(fds[0], addr(buf), 16), 0, "EOF after close")
    assert_equal(libc.close(fds[0]), 0)


def test_close_invalid_fd_sets_errno() raises:
    assert_equal(libc.close(-1), -1)
    assert_equal(libc.errno(), libc.EBADF)
    assert_true(libc.strerror(libc.EBADF) != "")


def test_fcntl_sets_close_on_exec() raises:
    var fds = List[c_int](length=2, fill=-1)
    assert_equal(libc.pipe(addr(fds)), 0)
    assert_equal(libc.fcntl(fds[0], libc.F_GETFD, 0) & libc.FD_CLOEXEC, 0)
    assert_equal(libc.fcntl(fds[0], libc.F_SETFD, libc.FD_CLOEXEC), 0)
    assert_equal(
        libc.fcntl(fds[0], libc.F_GETFD, 0) & libc.FD_CLOEXEC, libc.FD_CLOEXEC
    )
    _ = libc.close(fds[0])
    _ = libc.close(fds[1])


def test_open_and_access() raises:
    var dev_null = String("/dev/null")
    var fd = libc.open(cstr(dev_null), libc.O_RDONLY, 0)
    assert_true(fd >= 0)
    _ = libc.close(fd)
    var sh = String("/bin/sh")
    assert_equal(libc.access(cstr(sh), libc.X_OK), 0)
    var missing = String("/nonexistent/mogo-tester")
    assert_equal(libc.open(cstr(missing), libc.O_RDONLY, 0), -1)
    assert_equal(libc.access(cstr(missing), libc.X_OK), -1)


def test_pseudo_terminal_functions() raises:
    var master = libc.posix_openpt(libc.O_RDWR | libc.O_NOCTTY())
    assert_true(master >= 0)
    assert_equal(libc.grantpt(master), 0)
    assert_equal(libc.unlockpt(master), 0)
    var name_ptr = libc.ptsname(master)
    assert_not_equal(name_ptr, 0)
    assert_true(c_string_at(name_ptr).startswith("/dev/"))
    _ = libc.close(master)


def test_poll_reports_readable_pipe() raises:
    var fds = List[c_int](length=2, fill=-1)
    assert_equal(libc.pipe(addr(fds)), 0)
    var pollfd = List[UInt8](length=libc.POLLFD_SIZE, fill=0)
    store[c_int](Int(pollfd.unsafe_ptr()), fds[0])
    store[c_short](Int(pollfd.unsafe_ptr()) + 4, libc.POLLIN)
    assert_equal(libc.poll(addr(pollfd), 1, 0), 0, "empty pipe is not ready")
    var byte = String("x")
    _ = libc.write(fds[1], cstr(byte), 1)
    assert_equal(libc.poll(addr(pollfd), 1, 1000), 1)
    # revents is the 16-bit field at offset 6; POLLIN is in its low byte.
    assert_equal(c_short(pollfd[6]) & libc.POLLIN, libc.POLLIN)
    _ = libc.close(fds[0])
    _ = libc.close(fds[1])


def test_posix_spawn_and_waitpid() raises:
    var actions = List[UInt8](length=libc.SPAWN_FILE_ACTIONS_SIZE, fill=0)
    var attr = List[UInt8](length=libc.SPAWN_ATTR_SIZE, fill=0)
    assert_equal(libc.posix_spawn_file_actions_init(addr(actions)), 0)
    assert_equal(libc.posix_spawnattr_init(addr(attr)), 0)
    assert_equal(libc.posix_spawnattr_setpgroup(addr(attr), 0), 0)
    assert_equal(
        libc.posix_spawnattr_setflags(addr(attr), libc.POSIX_SPAWN_SETPGROUP),
        0,
    )
    var file = String("/bin/sh")
    var argv = CStringArray(["sh", "-c", "exit 7"])
    var envp = CStringArray([])
    var pid = List[c_int](length=1, fill=0)
    assert_equal(
        libc.posix_spawn(
            addr(pid),
            cstr(file),
            addr(actions),
            addr(attr),
            argv.ptr(),
            envp.ptr(),
        ),
        0,
    )
    _ = libc.posix_spawn_file_actions_destroy(addr(actions))
    _ = libc.posix_spawnattr_destroy(addr(attr))

    var status = List[c_int](length=1, fill=0)
    var reaped: c_int = 0
    for _ in range(500):
        reaped = libc.waitpid(pid[0], addr(status), libc.WNOHANG)
        if reaped != 0:
            break
        _ = libc.poll(vp(0), 0, 10)
    assert_equal(reaped, pid[0])
    assert_equal(status[0] & 0x7F, 0, "exited normally")
    assert_equal((status[0] >> 8) & 0xFF, 7)


def test_kill_terminates_process() raises:
    var file = String("/bin/sh")
    var argv = CStringArray(["sh", "-c", "sleep 30"])
    var envp = CStringArray([])
    var pid = List[c_int](length=1, fill=0)
    assert_equal(
        libc.posix_spawn(
            addr(pid), cstr(file), vp(0), vp(0), argv.ptr(), envp.ptr()
        ),
        0,
    )
    assert_equal(libc.kill(pid[0], libc.SIGKILL), 0)
    var status = List[c_int](length=1, fill=0)
    assert_equal(libc.waitpid(pid[0], addr(status), 0), pid[0])
    assert_equal(status[0] & 0x7F, libc.SIGKILL)


def test_sigset_and_sigaction_query() raises:
    var set = List[UInt8](length=libc.SIGSET_SIZE, fill=0xFF)
    assert_equal(libc.sigemptyset(addr(set)), 0)
    assert_equal(libc.sigaddset(addr(set), libc.SIGINT), 0)
    var action = List[Int](length=libc.SIGACTION_SIZE // 8, fill=-1)
    assert_equal(libc.sigaction(libc.SIGINT, vp(0), addr(action)), 0)
    assert_not_equal(action[0], -1, "the handler field was filled in")


def test_mkdtemp_creates_directory() raises:
    var template = List[UInt8](String("/tmp/mogo-libc-XXXXXX").as_bytes())
    template.append(0)
    assert_not_equal(libc.mkdtemp(addr(template)), 0)
    var path = String(unsafe_from_utf8=Span(template)[0 : len(template) - 1])
    assert_false(path.endswith("XXXXXX"))
    assert_equal(libc.access(cstr(path), libc.X_OK), 0)
    _ = libc.close(-1)  # leave errno untouched by later tests
    from std.os import rmdir

    rmdir(path)


def test_environ_lists_variables() raises:
    var entries = libc.environ()
    assert_not_equal(entries, 0)
    var first = load[Int](entries)
    assert_not_equal(first, 0)
    assert_true("=" in c_string_at(first))


def test_getpid_is_positive() raises:
    assert_true(libc.getpid() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
