"""File descriptor helpers built on the libc bindings: pipes, reads, and
poll(2) sets."""

from std.ffi import c_int, c_short

from . import libc
from .cffi import addr, load, store


def close_fd(fd: c_int):
    """Closes fd, ignoring errors."""
    _ = libc.close(fd)


def set_cloexec(fd: c_int):
    """Marks fd close-on-exec so spawned children do not inherit it."""
    var flags = libc.fcntl(fd, libc.F_GETFD, 0)
    if flags >= 0:
        _ = libc.fcntl(fd, libc.F_SETFD, flags | libc.FD_CLOEXEC)


def make_pipe() raises -> Tuple[c_int, c_int]:
    """Creates a close-on-exec pipe and returns (read_fd, write_fd).

    Raises:
        Error: If pipe(2) fails.
    """
    var fds = List[c_int](length=2, fill=0)
    if libc.pipe(addr(fds)) != 0:
        raise Error("pipe: ", libc.strerror(libc.errno()))
    set_cloexec(fds[0])
    set_cloexec(fds[1])
    return (fds[0], fds[1])


def read_fd(fd: c_int, mut buf: List[UInt8]) -> Int:
    """Reads up to len(buf) bytes, retrying on EINTR.

    Returns:
        The number of bytes read, 0 at end of file, or the negated errno.
    """
    while True:
        var n = libc.read(fd, addr(buf), len(buf))
        if n >= 0:
            return n
        var code = libc.errno()
        if code != libc.EINTR:
            return -Int(code)


struct PollSet(Movable):
    """A `struct pollfd[]` array that waits for descriptors to become
    readable."""

    var buf: List[UInt8]
    var count: Int

    def __init__(out self, fds: List[c_int]):
        self.count = len(fds)
        self.buf = List[UInt8](
            length=max(1, len(fds)) * libc.POLLFD_SIZE, fill=0
        )
        var base = Int(self.buf.unsafe_ptr())
        for i in range(len(fds)):
            store[c_int](base + i * libc.POLLFD_SIZE, fds[i])
            store[c_short](base + i * libc.POLLFD_SIZE + 4, libc.POLLIN)

    def wait(mut self, timeout_ms: Int) -> Int:
        """Waits up to timeout_ms; returns poll(2)'s result."""
        return Int(libc.poll(addr(self.buf), self.count, c_int(timeout_ms)))

    def ready(mut self, index: Int) -> Bool:
        """Reports whether descriptor index is readable or hung up."""
        var revents = load[c_short](
            Int(self.buf.unsafe_ptr()) + index * libc.POLLFD_SIZE + 6
        )
        return (revents & (libc.POLLIN | libc.POLLHUP | libc.POLLERR)) != 0
