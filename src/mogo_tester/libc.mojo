"""Direct Mojo bindings for the libc functions mogo-tester uses.

Each function is a one-to-one, always-inlined translation of the libc
function with the same name. Arguments and return values follow the C
contract: errors are reported through return values and `errno()`, and no
function here raises. Abstractions built on these bindings live in separate
modules (`fd`, `pty`, `spawn`, `signals`, `env`).
"""

from std.ffi import c_int, c_short, external_call
from std.sys import CompilationTarget
from std.sys._libc_errno import ErrNo, get_errno

from .cffi import VoidPtr, load, vp

comptime SignalHandler = def(c_int) thin abi("C") -> None
"""A C signal handler, `void (*)(int)`."""

# Sizes of opaque libc structs, rounded up so that both glibc and Darwin
# layouts fit.
comptime SPAWN_FILE_ACTIONS_SIZE = 256
comptime SPAWN_ATTR_SIZE = 512
comptime SIGSET_SIZE = 128
comptime SIGACTION_SIZE = 256
comptime POLLFD_SIZE = 8

comptime EINTR: c_int = 4
comptime EBADF: c_int = 9

comptime O_RDONLY: c_int = 0
comptime O_RDWR: c_int = 2

comptime F_GETFD: c_int = 1
comptime F_SETFD: c_int = 2
comptime FD_CLOEXEC: c_int = 1

comptime POLLIN: c_short = 0x1
comptime POLLERR: c_short = 0x8
comptime POLLHUP: c_short = 0x10

comptime WNOHANG: c_int = 1

comptime X_OK: c_int = 1

comptime SIGINT: c_int = 2
comptime SIGKILL: c_int = 9
comptime SIG_IGN = 1
"""The `SIG_IGN` disposition, as stored in `struct sigaction`."""

comptime POSIX_SPAWN_SETPGROUP: c_short = 0x02
comptime POSIX_SPAWN_SETSIGDEF: c_short = 0x04
comptime POSIX_SPAWN_SETSIGMASK: c_short = 0x08


@inline(.always)
def O_NOCTTY() -> c_int:
    """Returns the platform's `O_NOCTTY` open flag."""
    comptime if CompilationTarget.is_macos():
        return 0x20000
    else:
        return 0o400


# ===-----------------------------------------------------------------------===#
# errno.h, string.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def errno() -> c_int:
    """Returns the calling thread's `errno`."""
    return get_errno().value


@inline(.always)
def strerror(code: c_int) -> String:
    """Returns libc's message for an errno value."""
    return String(ErrNo(code))


# ===-----------------------------------------------------------------------===#
# unistd.h, fcntl.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def pipe(fildes: VoidPtr) -> c_int:
    """`int pipe(int fildes[2])`."""
    return external_call["pipe", c_int](fildes)


@inline(.always)
def close(fd: c_int) -> c_int:
    """`int close(int fd)`."""
    return external_call["close", c_int](fd)


@inline(.always)
def read(fd: c_int, buf: VoidPtr, count: Int) -> Int:
    """`ssize_t read(int fd, void *buf, size_t count)`."""
    return external_call["read", Int](fd, buf, count)


@inline(.always)
def write(fd: c_int, buf: VoidPtr, count: Int) -> Int:
    """`ssize_t write(int fd, const void *buf, size_t count)`."""
    return external_call["write", Int](fd, buf, count)


@inline(.always)
def fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int:
    """`int fcntl(int fd, int cmd, ...)` with one int argument."""
    return external_call["fcntl", c_int, num_fixed_args=2](fd, cmd, arg)


@inline(.always)
def open(path: VoidPtr, flags: c_int, mode: c_int) -> c_int:
    """`int open(const char *path, int flags, ...)`."""
    return external_call["open", c_int, num_fixed_args=2](path, flags, mode)


@inline(.always)
def access(path: VoidPtr, mode: c_int) -> c_int:
    """`int access(const char *path, int mode)`."""
    return external_call["access", c_int](path, mode)


@inline(.always)
def getpid() -> c_int:
    """`pid_t getpid(void)`."""
    return external_call["getpid", c_int]()


# ===-----------------------------------------------------------------------===#
# stdlib.h: pseudo-terminals, temporary directories, environment
# ===-----------------------------------------------------------------------===#


@inline(.always)
def posix_openpt(flags: c_int) -> c_int:
    """`int posix_openpt(int flags)`."""
    return external_call["posix_openpt", c_int](flags)


@inline(.always)
def grantpt(fd: c_int) -> c_int:
    """`int grantpt(int fd)`."""
    return external_call["grantpt", c_int](fd)


@inline(.always)
def unlockpt(fd: c_int) -> c_int:
    """`int unlockpt(int fd)`."""
    return external_call["unlockpt", c_int](fd)


@inline(.always)
def ptsname(fd: c_int) -> Int:
    """`char *ptsname(int fd)`; returns the string's address, or 0."""
    return external_call["ptsname", Int](fd)


@inline(.always)
def mkdtemp(template: VoidPtr) -> Int:
    """`char *mkdtemp(char *template)`; returns template's address, or 0."""
    return external_call["mkdtemp", Int](template)


@inline(.always)
def environ() -> Int:
    """Returns the value of the `char **environ` global, or 0."""
    comptime if CompilationTarget.is_macos():
        # `_NSGetEnviron()` returns `char ***`: the address of `environ`.
        return load[Int](external_call["_NSGetEnviron", Int]())
    else:
        # `dlsym(RTLD_DEFAULT, "environ")`; RTLD_DEFAULT is NULL on glibc.
        var symbol = String("environ")
        var holder = external_call["dlsym", Int](
            vp(0), vp(Int(symbol.as_c_string_span().ptr()))
        )
        _ = symbol^  # Keep the C string alive across the call.
        if holder == 0:
            return 0
        return load[Int](holder)


# ===-----------------------------------------------------------------------===#
# poll.h, sys/wait.h, signal.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def poll(fds: VoidPtr, nfds: Int, timeout_ms: c_int) -> c_int:
    """`int poll(struct pollfd *fds, nfds_t nfds, int timeout)`."""
    return external_call["poll", c_int](fds, UInt(nfds), timeout_ms)


@inline(.always)
def waitpid(pid: c_int, status: VoidPtr, options: c_int) -> c_int:
    """`pid_t waitpid(pid_t pid, int *status, int options)`."""
    return external_call["waitpid", c_int](pid, status, options)


@inline(.always)
def kill(pid: c_int, sig: c_int) -> c_int:
    """`int kill(pid_t pid, int sig)`."""
    return external_call["kill", c_int](pid, sig)


@inline(.always)
def signal(sig: c_int, handler: SignalHandler) -> Int:
    """`sighandler_t signal(int sig, sighandler_t handler)`; returns the
    previous handler's address."""
    return external_call["signal", Int](sig, handler)


@inline(.always)
def sigaction(sig: c_int, act: VoidPtr, oldact: VoidPtr) -> c_int:
    """`int sigaction(int sig, const struct sigaction *act,
    struct sigaction *oldact)`."""
    return external_call["sigaction", c_int](sig, act, oldact)


@inline(.always)
def sigemptyset(set: VoidPtr) -> c_int:
    """`int sigemptyset(sigset_t *set)`."""
    return external_call["sigemptyset", c_int](set)


@inline(.always)
def sigaddset(set: VoidPtr, sig: c_int) -> c_int:
    """`int sigaddset(sigset_t *set, int sig)`."""
    return external_call["sigaddset", c_int](set, sig)


# ===-----------------------------------------------------------------------===#
# spawn.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def posix_spawn(
    pid: VoidPtr,
    path: VoidPtr,
    file_actions: VoidPtr,
    attrp: VoidPtr,
    argv: VoidPtr,
    envp: VoidPtr,
) -> c_int:
    """`int posix_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])`.
    """
    return external_call["posix_spawn", c_int](
        pid, path, file_actions, attrp, argv, envp
    )


@inline(.always)
def posix_spawn_file_actions_init(file_actions: VoidPtr) -> c_int:
    """`int posix_spawn_file_actions_init(posix_spawn_file_actions_t *)`."""
    return external_call["posix_spawn_file_actions_init", c_int](file_actions)


@inline(.always)
def posix_spawn_file_actions_destroy(file_actions: VoidPtr) -> c_int:
    """`int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *)`."""
    return external_call["posix_spawn_file_actions_destroy", c_int](
        file_actions
    )


@inline(.always)
def posix_spawn_file_actions_addopen(
    file_actions: VoidPtr,
    fd: c_int,
    path: VoidPtr,
    oflag: c_int,
    mode: UInt16,
) -> c_int:
    """`int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *,
    int fd, const char *path, int oflag, mode_t mode)`."""
    return external_call["posix_spawn_file_actions_addopen", c_int](
        file_actions, fd, path, oflag, mode
    )


@inline(.always)
def posix_spawn_file_actions_adddup2(
    file_actions: VoidPtr, fd: c_int, newfd: c_int
) -> c_int:
    """`int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *,
    int fd, int newfd)`."""
    return external_call["posix_spawn_file_actions_adddup2", c_int](
        file_actions, fd, newfd
    )


@inline(.always)
def posix_spawnattr_init(attr: VoidPtr) -> c_int:
    """`int posix_spawnattr_init(posix_spawnattr_t *attr)`."""
    return external_call["posix_spawnattr_init", c_int](attr)


@inline(.always)
def posix_spawnattr_destroy(attr: VoidPtr) -> c_int:
    """`int posix_spawnattr_destroy(posix_spawnattr_t *attr)`."""
    return external_call["posix_spawnattr_destroy", c_int](attr)


@inline(.always)
def posix_spawnattr_setflags(attr: VoidPtr, flags: c_short) -> c_int:
    """`int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags)`."""
    return external_call["posix_spawnattr_setflags", c_int](attr, flags)


@inline(.always)
def posix_spawnattr_setpgroup(attr: VoidPtr, pgroup: c_int) -> c_int:
    """`int posix_spawnattr_setpgroup(posix_spawnattr_t *attr,
    pid_t pgroup)`."""
    return external_call["posix_spawnattr_setpgroup", c_int](attr, pgroup)


@inline(.always)
def posix_spawnattr_setsigmask(attr: VoidPtr, sigmask: VoidPtr) -> c_int:
    """`int posix_spawnattr_setsigmask(posix_spawnattr_t *attr,
    const sigset_t *sigmask)`."""
    return external_call["posix_spawnattr_setsigmask", c_int](attr, sigmask)


@inline(.always)
def posix_spawnattr_setsigdefault(attr: VoidPtr, sigdefault: VoidPtr) -> c_int:
    """`int posix_spawnattr_setsigdefault(posix_spawnattr_t *attr,
    const sigset_t *sigdefault)`."""
    return external_call["posix_spawnattr_setsigdefault", c_int](
        attr, sigdefault
    )
