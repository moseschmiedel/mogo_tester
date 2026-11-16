"""Thin libc bindings used for process spawning, PTYs, polling, and signals.

Pointers cross the FFI boundary as `VoidPtr` built from integer addresses.
Every buffer handed to libc is owned by a Mojo `List` that the caller keeps
alive for the duration of the call.
"""

from std.ffi import external_call, c_int, c_short
from std.os import getenv
from std.os.path import isfile
from std.sys import CompilationTarget
from std.sys._libc_errno import ErrNo, get_errno

comptime VoidPtr = MutOpaquePointer[MutAnyOrigin]
comptime BytePtr = ImmPointer[UInt8, ImmutAnyOrigin]

# Opaque libc struct sizes, rounded up generously so that both glibc and
# Darwin layouts fit.
comptime SPAWN_FILE_ACTIONS_SIZE = 256
comptime SPAWN_ATTR_SIZE = 512
comptime SIGSET_SIZE = 128
comptime POLLFD_SIZE = 8

comptime O_RDONLY: c_int = 0
comptime O_RDWR: c_int = 2

comptime POLLIN: c_short = 0x1
comptime POLLERR: c_short = 0x8
comptime POLLHUP: c_short = 0x10

comptime F_GETFD: c_int = 1
comptime F_SETFD: c_int = 2
comptime FD_CLOEXEC: c_int = 1

comptime WNOHANG: c_int = 1

comptime SIGINT: c_int = 2
comptime SIGKILL: c_int = 9

comptime POSIX_SPAWN_SETPGROUP: c_short = 0x02
comptime POSIX_SPAWN_SETSIGDEF: c_short = 0x04
comptime POSIX_SPAWN_SETSIGMASK: c_short = 0x08


def _o_noctty() -> c_int:
    comptime if CompilationTarget.is_macos():
        return 0x20000
    else:
        return 0o400


def vp(address: Int) -> VoidPtr:
    """Returns an opaque pointer for an integer address."""
    return VoidPtr(unsafe_from_address=address)


def addr(mut buf: List[UInt8]) -> Int:
    """Returns the address of a byte buffer's first element."""
    return Int(buf.unsafe_ptr())


def errno() -> Int:
    """Returns the calling thread's current errno value."""
    return Int(get_errno().value)


def strerror(code: Int) -> String:
    """Returns libc's message for an errno value."""
    return String(ErrNo(c_int(code)))


def c_string_at(address: Int) -> String:
    """Copies the NUL-terminated C string at address into a String."""
    return String(unsafe_from_utf8_ptr=BytePtr(unsafe_from_address=address))


struct CStringArray(Movable):
    """A NULL-terminated `char *[]` that owns the strings it points to."""

    var strings: List[String]
    var pointers: List[Int]

    def __init__(out self, values: List[String]):
        self.strings = List[String](capacity=len(values))
        for value in values:
            self.strings.append(value)
        self.pointers = List[Int](capacity=len(values) + 1)
        for i in range(len(self.strings)):
            self.pointers.append(Int(self.strings[i].as_c_string_span().ptr()))
        self.pointers.append(0)

    def ptr(mut self) -> VoidPtr:
        """Returns the address of the pointer array."""
        return vp(Int(self.pointers.unsafe_ptr()))


def current_environment() -> List[String]:
    """Returns the process environment as `KEY=VALUE` entries."""
    var environ: Int
    comptime if CompilationTarget.is_macos():
        var holder = external_call["_NSGetEnviron", Int]()
        environ = Pointer[Int, ImmutAnyOrigin](unsafe_from_address=holder)[]
    else:
        var symbol = String("environ")
        var holder = external_call["dlsym", Int](
            vp(0), vp(Int(symbol.as_c_string_span().ptr()))
        )
        environ = Pointer[Int, ImmutAnyOrigin](unsafe_from_address=holder)[]

    var result = List[String]()
    if environ == 0:
        return result^
    var entries = Pointer[Int, ImmutAnyOrigin](unsafe_from_address=environ)
    var i = 0
    while True:
        var entry = entries.unsafe_offset(i)[]
        if entry == 0:
            break
        result.append(c_string_at(entry))
        i += 1
    return result^


def close_fd(fd: c_int):
    """Closes fd, ignoring errors."""
    _ = external_call["close", c_int](fd)


def set_cloexec(fd: c_int):
    """Marks fd close-on-exec so spawned children do not inherit it."""
    var flags = external_call["fcntl", c_int, num_fixed_args=2](
        fd, F_GETFD, c_int(0)
    )
    if flags >= 0:
        _ = external_call["fcntl", c_int, num_fixed_args=2](
            fd, F_SETFD, flags | FD_CLOEXEC
        )


def make_pipe() raises -> Tuple[c_int, c_int]:
    """Creates a close-on-exec pipe and returns (read_fd, write_fd)."""
    var fds = List[c_int](length=2, fill=0)
    if external_call["pipe", c_int](vp(Int(fds.unsafe_ptr()))) != 0:
        raise Error("pipe: ", strerror(errno()))
    set_cloexec(fds[0])
    set_cloexec(fds[1])
    return (fds[0], fds[1])


def open_pty() raises -> Tuple[c_int, c_int]:
    """Opens a pseudo-terminal pair and returns (master_fd, slave_fd)."""
    var master = external_call["posix_openpt", c_int](O_RDWR | _o_noctty())
    if master < 0:
        raise Error("open pty: ", strerror(errno()))
    if external_call["grantpt", c_int](master) != 0:
        var message = strerror(errno())
        close_fd(master)
        raise Error("grantpt: ", message)
    if external_call["unlockpt", c_int](master) != 0:
        var message = strerror(errno())
        close_fd(master)
        raise Error("unlockpt: ", message)
    var name_ptr = external_call["ptsname", Int](master)
    if name_ptr == 0:
        var message = strerror(errno())
        close_fd(master)
        raise Error("ptsname: ", message)
    var name = c_string_at(name_ptr)
    var slave = external_call["open", c_int, num_fixed_args=2](
        name.as_c_string_span(), O_RDWR | _o_noctty(), c_int(0)
    )
    if slave < 0:
        var message = strerror(errno())
        close_fd(master)
        raise Error("open ", name, ": ", message)
    set_cloexec(master)
    set_cloexec(slave)
    return (master, slave)


def read_fd(fd: c_int, mut buf: List[UInt8]) -> Int:
    """Reads up to len(buf) bytes; returns the count, 0 at EOF, or -errno."""
    while True:
        var n = external_call["read", Int](fd, vp(addr(buf)), len(buf))
        if n >= 0:
            return n
        var code = errno()
        if code != 4:  # EINTR
            return -code


def write_all(fd: c_int, text: String):
    """Writes the whole string to fd, retrying short writes."""
    var bytes = text.as_bytes()
    var offset = 0
    var base = Int(bytes.unsafe_ptr())
    while offset < len(bytes):
        var n = external_call["write", Int](
            fd, vp(base + offset), len(bytes) - offset
        )
        if n <= 0:
            if n < 0 and errno() == 4:
                continue
            return
        offset += n


struct SpawnRequest(Movable):
    """Executable, file descriptor wiring, and environment for one spawn."""

    var file: String
    var argv: List[String]
    var env: List[String]
    var stdout_fd: c_int
    var stderr_fd: c_int

    def __init__(
        out self,
        var file: String,
        var argv: List[String],
        var env: List[String],
        stdout_fd: c_int,
        stderr_fd: c_int,
    ):
        self.file = file^
        self.argv = argv^
        self.env = env^
        self.stdout_fd = stdout_fd
        self.stderr_fd = stderr_fd


def spawn(mut request: SpawnRequest) raises -> c_int:
    """Spawns request.file with stdin from /dev/null and stdout/stderr
    attached to the requested descriptors. Returns the child pid.

    The child starts with an empty signal mask and default SIGINT handling,
    and leads a new process group so that `kill_group` also reaches any
    processes it starts.
    """
    var actions = List[UInt8](length=SPAWN_FILE_ACTIONS_SIZE, fill=0)
    var attr = List[UInt8](length=SPAWN_ATTR_SIZE, fill=0)
    var empty_set = List[UInt8](length=SIGSET_SIZE, fill=0)
    var dev_null = String("/dev/null")

    if (
        external_call["posix_spawn_file_actions_init", c_int](vp(addr(actions)))
        != 0
    ):
        raise Error("posix_spawn_file_actions_init failed")
    if external_call["posix_spawnattr_init", c_int](vp(addr(attr))) != 0:
        _ = external_call["posix_spawn_file_actions_destroy", c_int](
            vp(addr(actions))
        )
        raise Error("posix_spawnattr_init failed")

    _ = external_call["posix_spawn_file_actions_addopen", c_int](
        vp(addr(actions)),
        c_int(0),
        vp(Int(dev_null.as_c_string_span().ptr())),
        O_RDONLY,
        UInt16(0),
    )
    _ = external_call["posix_spawn_file_actions_adddup2", c_int](
        vp(addr(actions)), request.stdout_fd, c_int(1)
    )
    _ = external_call["posix_spawn_file_actions_adddup2", c_int](
        vp(addr(actions)), request.stderr_fd, c_int(2)
    )
    _ = external_call["sigemptyset", c_int](vp(addr(empty_set)))
    var default_set = List[UInt8](length=SIGSET_SIZE, fill=0)
    _ = external_call["sigemptyset", c_int](vp(addr(default_set)))
    _ = external_call["sigaddset", c_int](vp(addr(default_set)), SIGINT)
    _ = external_call["posix_spawnattr_setsigdefault", c_int](
        vp(addr(attr)), vp(addr(default_set))
    )
    _ = external_call["posix_spawnattr_setsigmask", c_int](
        vp(addr(attr)), vp(addr(empty_set))
    )
    _ = external_call["posix_spawnattr_setpgroup", c_int](
        vp(addr(attr)), c_int(0)
    )
    _ = external_call["posix_spawnattr_setflags", c_int](
        vp(addr(attr)),
        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP,
    )

    var argv = CStringArray(request.argv)
    var envp = CStringArray(request.env)
    var pid = List[c_int](length=1, fill=0)
    var rc = external_call["posix_spawn", c_int](
        vp(Int(pid.unsafe_ptr())),
        vp(Int(request.file.as_c_string_span().ptr())),
        vp(addr(actions)),
        vp(addr(attr)),
        argv.ptr(),
        envp.ptr(),
    )
    _ = external_call["posix_spawn_file_actions_destroy", c_int](
        vp(addr(actions))
    )
    _ = external_call["posix_spawnattr_destroy", c_int](vp(addr(attr)))
    _ = dev_null^
    _ = empty_set^
    _ = default_set^
    if rc != 0:
        raise Error(strerror(Int(rc)))
    return pid[0]


def wait_pid(pid: c_int, block: Bool) -> Optional[c_int]:
    """Reaps pid. Returns the raw wait status, or None if it is still
    running (non-blocking) or cannot be waited for."""
    var status = List[c_int](length=1, fill=0)
    var options = c_int(0) if block else WNOHANG
    while True:
        var rc = external_call["waitpid", c_int](
            pid, vp(Int(status.unsafe_ptr())), options
        )
        if rc == pid:
            return status[0]
        if rc == 0:
            return None
        if errno() == 4:
            continue
        return None


def is_executable(mut path: String) -> Bool:
    """Reports whether path names an executable regular file."""
    comptime X_OK: c_int = 1
    if not isfile(path):
        return False
    return (
        external_call["access", c_int](
            vp(Int(path.as_c_string_span().ptr())), X_OK
        )
        == 0
    )


def kill_pid(pid: c_int, signal: c_int):
    """Sends signal to pid, ignoring errors."""
    _ = external_call["kill", c_int](pid, signal)


def kill_group(pid: c_int, signal: c_int):
    """Sends signal to the process group led by pid, ignoring errors."""
    _ = external_call["kill", c_int](-pid, signal)


struct PollSet(Movable):
    """A `struct pollfd[]` array for poll(2)."""

    var buf: List[UInt8]
    var count: Int

    def __init__(out self, fds: List[c_int]):
        self.count = len(fds)
        self.buf = List[UInt8](length=max(1, len(fds)) * POLLFD_SIZE, fill=0)
        var base = Int(self.buf.unsafe_ptr())
        for i in range(len(fds)):
            Pointer[c_int, MutAnyOrigin](
                unsafe_from_address=base + i * POLLFD_SIZE
            )[] = fds[i]
            Pointer[c_short, MutAnyOrigin](
                unsafe_from_address=base + i * POLLFD_SIZE + 4
            )[] = POLLIN

    def wait(mut self, timeout_ms: Int) -> Int:
        """Polls the descriptors; returns poll(2)'s result."""
        return Int(
            external_call["poll", c_int](
                vp(addr(self.buf)), UInt(self.count), c_int(timeout_ms)
            )
        )

    def ready(mut self, index: Int) -> Bool:
        """Reports whether descriptor index is readable or hung up."""
        var revents = Pointer[c_short, MutAnyOrigin](
            unsafe_from_address=addr(self.buf) + index * POLLFD_SIZE + 6
        )[]
        return (revents & (POLLIN | POLLHUP | POLLERR)) != 0


# Large enough for `struct sigaction` on glibc (152 bytes) and Darwin (16).
# Both layouts start with the handler pointer.
comptime SIGACTION_WORDS = 32
comptime SIG_IGN = 1


def _set_sigint_ignored() -> None:
    var action = Array[Int, SIGACTION_WORDS](fill=0)
    action[0] = SIG_IGN
    _ = external_call["sigaction", c_int](
        SIGINT, vp(Int(action.unsafe_ptr())), vp(0)
    )


def _on_sigint(sig: c_int) abi("C"):
    """One-shot SIGINT handler: records the signal by switching SIGINT's
    disposition to ignored. sigaction is async-signal-safe, and later
    Ctrl-C presses are ignored while mogo-tester shuts down."""
    _set_sigint_ignored()


struct InterruptGuard(Movable):
    """Turns SIGINT into an observable event so Ctrl-C can be handled with
    `interrupted()` instead of terminating the process immediately.

    The Mojo runtime starts threads before `main`, so blocking the signal
    with sigprocmask would not cover them, and Mojo has no global variables
    for a handler to set. The handler instead stores the event in the kernel:
    it sets SIGINT's disposition to ignored, which `interrupted()` queries.
    """

    var seen: Bool

    def __init__(out self):
        self.seen = False
        comptime Handler = def(c_int) thin abi("C") -> None
        var handler: Handler = _on_sigint
        _ = external_call["signal", Int](SIGINT, handler)

    def interrupted(mut self) -> Bool:
        """Reports whether SIGINT has been received since construction."""
        if not self.seen:
            var current = Array[Int, SIGACTION_WORDS](fill=0)
            if (
                external_call["sigaction", c_int](
                    SIGINT, vp(0), vp(Int(current.unsafe_ptr()))
                )
                == 0
            ):
                self.seen = current[0] == SIG_IGN
        return self.seen


def signal_name(sig: Int) -> String:
    """Returns the lowercase signal description used in error messages."""
    if sig == 1:
        return "hangup"
    if sig == 2:
        return "interrupt"
    if sig == 3:
        return "quit"
    if sig == 4:
        return "illegal instruction"
    if sig == 5:
        return "trace/breakpoint trap"
    if sig == 6:
        comptime if CompilationTarget.is_macos():
            return "abort trap"
        else:
            return "aborted"
    if sig == 8:
        return "floating point exception"
    if sig == 9:
        return "killed"
    if sig == 11:
        return "segmentation fault"
    if sig == 13:
        return "broken pipe"
    if sig == 14:
        return "alarm clock"
    if sig == 15:
        return "terminated"
    comptime if CompilationTarget.is_macos():
        if sig == 10:
            return "bus error"
    else:
        if sig == 7:
            return "bus error"
    return String("signal ", sig)


def local_timestamp() -> String:
    """Returns the current local time as RFC 3339 with milliseconds."""
    var tv = List[Int](length=2, fill=0)
    _ = external_call["gettimeofday", c_int](vp(Int(tv.unsafe_ptr())), vp(0))
    var seconds = List[Int](length=1, fill=tv[0])
    var tm = List[UInt8](length=128, fill=0)
    _ = external_call["localtime_r", Int](
        vp(Int(seconds.unsafe_ptr())), vp(addr(tm))
    )
    var out = List[UInt8](length=64, fill=0)
    var fmt = String("%Y-%m-%dT%H:%M:%S")
    var n = external_call["strftime", Int](
        vp(addr(out)), 64, vp(Int(fmt.as_c_string_span().ptr())), vp(addr(tm))
    )
    var zone = List[UInt8](length=16, fill=0)
    var zfmt = String("%z")
    var zn = external_call["strftime", Int](
        vp(addr(zone)), 16, vp(Int(zfmt.as_c_string_span().ptr())), vp(addr(tm))
    )
    var micros: Int
    comptime if CompilationTarget.is_macos():
        # Darwin's suseconds_t is 32-bit and follows a 64-bit time_t.
        micros = tv[1] & 0xFFFFFFFF
    else:
        micros = tv[1]
    var millis = String(micros // 1000)
    while millis.byte_length() < 3:
        millis = "0" + millis
    var result = String(unsafe_from_utf8=Span(out)[0:n]) + "." + millis
    var z = String(unsafe_from_utf8=Span(zone)[0:zn])
    if z == "+0000" or z == "-0000":
        return result + "Z"
    if z.byte_length() == 5:
        return result + z[byte=0:3] + ":" + z[byte=3:5]
    return result + z


def make_temp_dir(prefix: String) raises -> String:
    """Creates a unique mode-0700 directory under $TMPDIR (or /tmp) with
    mkdtemp(3) and returns its path."""
    var root = String(getenv("TMPDIR", "/tmp").rstrip("/"))
    if root == "":
        root = "/"
    var template = String(root, "/", prefix, "XXXXXXXX")
    var bytes = List[UInt8](template.as_bytes())
    bytes.append(0)
    var result = external_call["mkdtemp", Int](vp(addr(bytes)))
    if result == 0:
        raise Error("mkdtemp ", template, ": ", strerror(errno()))
    # mkdtemp fills in the template in place.
    return String(unsafe_from_utf8=Span(bytes)[0 : len(bytes) - 1])
