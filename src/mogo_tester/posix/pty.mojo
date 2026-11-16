"""Pseudo-terminal allocation."""

from std.ffi import c_int

from . import libc
from .cffi import c_string_at, cstr
from .fd import close_fd, set_cloexec


def open_pty() raises -> Tuple[c_int, c_int]:
    """Opens a close-on-exec pseudo-terminal pair.

    Returns:
        The (master_fd, slave_fd) pair.

    Raises:
        Error: If the platform cannot allocate a pseudo-terminal.
    """
    var master = libc.posix_openpt(libc.O_RDWR | libc.O_NOCTTY())
    if master < 0:
        raise Error("open pty: ", libc.strerror(libc.errno()))
    if libc.grantpt(master) != 0:
        var message = libc.strerror(libc.errno())
        close_fd(master)
        raise Error("grantpt: ", message)
    if libc.unlockpt(master) != 0:
        var message = libc.strerror(libc.errno())
        close_fd(master)
        raise Error("unlockpt: ", message)
    var name_ptr = libc.ptsname(master)
    if name_ptr == 0:
        var message = libc.strerror(libc.errno())
        close_fd(master)
        raise Error("ptsname: ", message)
    var name = c_string_at(name_ptr)
    var slave = libc.open(cstr(name), libc.O_RDWR | libc.O_NOCTTY(), 0)
    # Raw pointers do not keep their owner alive; hold name until here.
    var opened = name^
    if slave < 0:
        var message = libc.strerror(libc.errno())
        close_fd(master)
        raise Error("open ", opened, ": ", message)
    set_cloexec(master)
    set_cloexec(slave)
    return (master, slave)
