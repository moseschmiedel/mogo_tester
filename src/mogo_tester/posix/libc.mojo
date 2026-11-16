"""Direct Mojo bindings for the libc functions mogo-tester uses.

Each function is a one-to-one, always-inlined translation of the libc
function with the same name. Arguments and return values follow the C
contract: most failures return -1 and set `errno()`. The `posix_spawn*`
functions return an error number directly instead. No function here raises.

Raw pointers do not retain their owners. Keep every buffer and C string
alive until the call returns, including an explicit later use of its owner
when needed (for example `_ = value^`). Buffers must have the size and
alignment required by the corresponding C type; the size constants below
provide storage bounds, not alignment. A NULL pointer is allowed only where
the function documents it.

Abstractions built on these bindings live in separate modules (`fd`, `pty`,
`spawn`, `signals`, `env`).
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
    """Returns the open flag that prevents acquiring a controlling terminal."""
    comptime if CompilationTarget.is_macos():
        return 0x20000
    else:
        return 0o400


# ===-----------------------------------------------------------------------===#
# errno.h, string.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def errno() -> c_int:
    """Returns the calling thread's current libc error number.

    Read immediately after a call reports failure; successful calls need
    not clear it, and intervening calls may overwrite it.
    """
    return get_errno().value


@inline(.always)
def strerror(code: c_int) -> String:
    """Copies libc's description of an error number into a Mojo String.

    Args:
        code: An errno value, including error numbers returned directly by
            the spawn functions.

    Returns:
        An owned message that does not borrow libc's message buffer.
    """
    return String(ErrNo(code))


# ===-----------------------------------------------------------------------===#
# unistd.h, fcntl.h
# ===-----------------------------------------------------------------------===#


@inline(.always)
def pipe(fildes: VoidPtr) -> c_int:
    """Creates a pipe and writes its read and write descriptors to fildes.

    Args:
        fildes: Writable storage for two c_int values. On success, index 0
            receives the read end and index 1 receives the write end.

    Returns:
        0 on success, or -1 with errno set. The caller owns both descriptors
        and must close them.
    """
    return external_call["pipe", c_int](fildes)


@inline(.always)
def close(fd: c_int) -> c_int:
    """Closes a file descriptor.

    Args:
        fd: An open descriptor owned by the caller.

    Returns:
        0 on success, or -1 with errno set. Do not blindly retry after EINTR:
        the descriptor may already have been released.
    """
    return external_call["close", c_int](fd)


@inline(.always)
def read(fd: c_int, buf: VoidPtr, count: Int) -> Int:
    """Reads up to count bytes from a descriptor into buf.

    Args:
        fd: A descriptor open for reading; the call may block.
        buf: Writable storage for at least count bytes.
        count: Nonnegative maximum number of bytes to read.

    Returns:
        Bytes read, which may be less than count; 0 means EOF when count is
        positive. Returns -1 with errno set on failure.
    """
    return external_call["read", Int](fd, buf, count)


@inline(.always)
def write(fd: c_int, buf: VoidPtr, count: Int) -> Int:
    """Writes up to count bytes from buf to a descriptor.

    Args:
        fd: A descriptor open for writing; the call may block. Writing to a
            closed pipe may deliver SIGPIPE.
        buf: Readable storage containing at least count bytes.
        count: Nonnegative maximum number of bytes to write.

    Returns:
        Bytes written, which may be less than count, or -1 with errno set.
        The caller must handle partial writes.
    """
    return external_call["write", Int](fd, buf, count)


@inline(.always)
def fcntl(fd: c_int, cmd: c_int, arg: c_int) -> c_int:
    """Performs a descriptor control operation with one integer argument.

    Args:
        fd: An open file descriptor.
        cmd: An fcntl command that takes an integer or ignores arg; commands
            requiring a pointer are not supported by this binding.
        arg: Command-specific value; use 0 when cmd ignores it.

    Returns:
        The command's result (flags for F_GETFD, 0 for F_SETFD), or -1 with
        errno set on failure.
    """
    return external_call["fcntl", c_int, num_fixed_args=2](fd, cmd, arg)


@inline(.always)
def open(path: VoidPtr, flags: c_int, mode: c_int) -> c_int:
    """Opens a path and returns an owned file descriptor.

    Args:
        path: Readable NUL-terminated pathname.
        flags: Open access mode and option bits, such as O_RDONLY or O_RDWR.
        mode: Creation permission bits when flags request file creation;
            otherwise ignored. The process umask filters these bits.

    Returns:
        A nonnegative descriptor the caller must close, or -1 with errno set.
    """
    return external_call["open", c_int, num_fixed_args=2](path, flags, mode)


@inline(.always)
def access(path: VoidPtr, mode: c_int) -> c_int:
    """Checks pathname permissions using the process's real user/group IDs.

    Args:
        path: Readable NUL-terminated pathname.
        mode: Permission mask (such as X_OK), or 0 to test existence.

    Returns:
        0 if the check succeeds, or -1 with errno set. The result does not
        guarantee that a later open or execution will succeed.
    """
    return external_call["access", c_int](path, mode)


@inline(.always)
def getpid() -> c_int:
    """Returns the calling process's positive process ID."""
    return external_call["getpid", c_int]()


# ===-----------------------------------------------------------------------===#
# stdlib.h: pseudo-terminals, temporary directories, environment
# ===-----------------------------------------------------------------------===#


@inline(.always)
def posix_openpt(flags: c_int) -> c_int:
    """Opens a new pseudo-terminal master.

    Args:
        flags: Open flags; use O_RDWR | O_NOCTTY() for a read/write master
            that does not become the controlling terminal.

    Returns:
        A nonnegative descriptor the caller must close, or -1 with errno set.
        Grant access and unlock the slave before opening it.
    """
    return external_call["posix_openpt", c_int](flags)


@inline(.always)
def grantpt(fd: c_int) -> c_int:
    """Sets ownership and permissions on a pseudo-terminal slave.

    Args:
        fd: An open pseudo-terminal master from posix_openpt.

    Returns:
        0 on success, or -1 with errno set.
    """
    return external_call["grantpt", c_int](fd)


@inline(.always)
def unlockpt(fd: c_int) -> c_int:
    """Unlocks a pseudo-terminal slave so it can be opened.

    Args:
        fd: An open pseudo-terminal master, normally after grantpt succeeds.

    Returns:
        0 on success, or -1 with errno set.
    """
    return external_call["unlockpt", c_int](fd)


@inline(.always)
def ptsname(fd: c_int) -> Int:
    """Returns the address of a pseudo-terminal slave's pathname.

    Args:
        fd: An open pseudo-terminal master.

    Returns:
        The address of a libc-owned NUL-terminated string, or 0 on failure.
        Do not free or modify it; copy it before another ptsname call can
        overwrite the shared storage. Concurrent calls require coordination.
    """
    return external_call["ptsname", Int](fd)


@inline(.always)
def mkdtemp(template: VoidPtr) -> Int:
    """Creates a private temporary directory by modifying template in place.

    Args:
        template: Writable NUL-terminated pathname ending in six X characters.
            The X characters are replaced with a unique suffix.

    Returns:
        The address of template on success, or 0 with errno set on failure.
        The directory has mode 0700; the caller must remove it when finished.
        The returned pointer remains valid only while template stays alive.
    """
    return external_call["mkdtemp", Int](template)


@inline(.always)
def environ() -> Int:
    """Returns the address of the process's environment pointer array.

    Returns:
        A libc-owned, NULL-terminated array of pointers to NUL-terminated
        NAME=value strings, or 0 if unavailable. Do not free the array or
        strings. Copy entries before environment mutation can invalidate
        them, and coordinate reads with concurrent environment changes.
    """
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
    """Waits for descriptor events and fills each entry's revents field.

    Args:
        fds: Writable array of nfds C pollfd structs (POLLFD_SIZE bytes each),
            with fd and events initialized; may be NULL when nfds is 0.
            Negative fd entries are ignored.
        nfds: Nonnegative number of entries in fds.
        timeout_ms: Maximum wait in milliseconds; 0 checks immediately and
            a negative value waits indefinitely.

    Returns:
        Number of entries with nonzero revents, 0 on timeout, or -1 with
        errno set (including EINTR when interrupted by a signal).
    """
    return external_call["poll", c_int](fds, UInt(nfds), timeout_ms)


@inline(.always)
def waitpid(pid: c_int, status: VoidPtr, options: c_int) -> c_int:
    """Waits for a child state change and optionally collects its status.

    Args:
        pid: Positive for one child, -1 for any child, 0 for children in the
            caller's process group, or below -1 for children in group -pid.
        status: Writable storage for one c_int encoded wait status, or NULL
            to discard it. Written only when a child's status is returned.
        options: Wait option bits; WNOHANG returns without blocking.

    Returns:
        The child's PID, 0 if WNOHANG finds no status available, or -1 with
        errno set. Collecting an exited child's status reaps it.
    """
    return external_call["waitpid", c_int](pid, status, options)


@inline(.always)
def kill(pid: c_int, sig: c_int) -> c_int:
    """Sends a signal to a process or process group.

    Args:
        pid: Positive for one process, 0 for the caller's process group,
            below -1 for process group -pid, or -1 for all permitted processes
            subject to platform exclusions.
        sig: Signal number; 0 checks existence and permission without sending.

    Returns:
        0 on success, or -1 with errno set.
    """
    return external_call["kill", c_int](pid, sig)


@inline(.always)
def signal(sig: c_int, handler: SignalHandler) -> Int:
    """Installs a process-wide signal handler.

    Args:
        sig: A catchable signal number; SIGKILL and SIGSTOP cannot be handled.
        handler: A thin C-ABI function that remains valid while installed.
            It must use only async-signal-safe operations when invoked.

    Returns:
        The previous handler's address (possibly SIG_DFL or SIG_IGN), or
        SIG_ERR (-1) with errno set. Prefer sigaction for explicit flags
        and masks; signal semantics depend on the platform.
    """
    return external_call["signal", Int](sig, handler)


@inline(.always)
def sigaction(sig: c_int, act: VoidPtr, oldact: VoidPtr) -> c_int:
    """Queries or changes a process-wide signal disposition.

    Args:
        sig: Signal number; changing SIGKILL or SIGSTOP is not allowed.
        act: Pointer to an initialized C sigaction struct, or NULL to leave
            the disposition unchanged. Installed handlers must remain valid
            and use only async-signal-safe operations.
        oldact: Writable sigaction storage for the previous disposition, or
            NULL to discard it. Each non-NULL buffer needs SIGACTION_SIZE
            bytes with C struct alignment and the platform's field layout.

    Returns:
        0 on success, or -1 with errno set. The structs are copied during
        the call; libc does not retain their storage.
    """
    return external_call["sigaction", c_int](sig, act, oldact)


@inline(.always)
def sigemptyset(set: VoidPtr) -> c_int:
    """Initializes a signal set to contain no signals.

    Args:
        set: Writable, C-aligned sigset_t storage of at least SIGSET_SIZE bytes.

    Returns:
        0 on success, or -1 with errno set.
    """
    return external_call["sigemptyset", c_int](set)


@inline(.always)
def sigaddset(set: VoidPtr, sig: c_int) -> c_int:
    """Adds a signal to an initialized signal set.

    Args:
        set: Writable sigset_t storage initialized by sigemptyset or another
            libc signal-set initializer; needs SIGSET_SIZE bytes and C alignment.
        sig: Valid signal number to add. This changes only the set in memory,
            not the calling thread's signal mask.

    Returns:
        0 on success, or -1 with errno set.
    """
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
    """Starts an executable with supplied arguments, environment, and actions.

    Args:
        pid: Writable storage for one c_int child PID, valid on success.
        path: Readable NUL-terminated executable path; PATH is not searched.
        file_actions: Initialized posix_spawn_file_actions_t, or NULL for
            default descriptor handling. Keep it alive through the call.
        attrp: Initialized posix_spawnattr_t, or NULL for default attributes.
            Keep it alive through the call.
        argv: Readable NULL-terminated array of NUL-terminated argument strings;
            argv[0] should name the executable. Keep array and strings alive.
        envp: Readable NULL-terminated array of NUL-terminated NAME=value
            strings. An empty array passes an empty environment; NULL does
            not request inheritance. Keep array and strings alive.

    Returns:
        0 on success, or an error number directly (not through errno).
        Success can still be followed by a child setup/exec failure with
        exit status 127. The caller must reap the child with waitpid.
    """
    return external_call["posix_spawn", c_int](
        pid, path, file_actions, attrp, argv, envp
    )


@inline(.always)
def posix_spawn_file_actions_init(file_actions: VoidPtr) -> c_int:
    """Initializes an empty spawn file-action object.

    Args:
        file_actions: Uninitialized writable posix_spawn_file_actions_t storage
            with C alignment and at least SPAWN_FILE_ACTIONS_SIZE bytes.

    Returns:
        0 on success, or an error number directly. After success, keep the
        object alive until its last spawn and destroy it to release resources.
    """
    return external_call["posix_spawn_file_actions_init", c_int](file_actions)


@inline(.always)
def posix_spawn_file_actions_destroy(file_actions: VoidPtr) -> c_int:
    """Releases resources held by a spawn file-action object.

    Args:
        file_actions: Successfully initialized posix_spawn_file_actions_t that
            is no longer in use by a spawn call. The caller owns its storage.

    Returns:
        0 on success, or an error number directly. The object must be
        reinitialized before reuse; this does not close the parent's descriptors.
    """
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
    """Appends an action that opens a pathname on a descriptor in the child.

    Args:
        file_actions: Initialized writable spawn file-action object. Actions
            run in insertion order before exec.
        fd: Nonnegative descriptor number to open in the child, replacing it
            if already open. The parent's descriptor is unchanged.
        path: Readable NUL-terminated pathname; libc copies it during this call.
        oflag: Open access mode and option bits for the child-side open.
        mode: Creation permission bits, filtered by umask; ignored unless
            oflag requests file creation.

    Returns:
        0 on success, or an error number directly. This queues the open;
        pathname and permission failures may occur later during spawning.
    """
    return external_call["posix_spawn_file_actions_addopen", c_int](
        file_actions, fd, path, oflag, mode
    )


@inline(.always)
def posix_spawn_file_actions_adddup2(
    file_actions: VoidPtr, fd: c_int, newfd: c_int
) -> c_int:
    """Appends an action that duplicates a descriptor in the child.

    Args:
        file_actions: Initialized writable spawn file-action object. Actions
            run in insertion order before exec.
        fd: Nonnegative source descriptor; must be open when this action runs.
        newfd: Nonnegative destination descriptor, replaced if already open.
            If equal to fd, the action clears close-on-exec on that descriptor.

    Returns:
        0 on success, or an error number directly. The parent's descriptors
        are unchanged; descriptor failures may occur later during spawning.
    """
    return external_call["posix_spawn_file_actions_adddup2", c_int](
        file_actions, fd, newfd
    )


@inline(.always)
def posix_spawnattr_init(attr: VoidPtr) -> c_int:
    """Initializes a spawn attribute object with libc's defaults.

    Args:
        attr: Uninitialized writable posix_spawnattr_t storage with C alignment
            and at least SPAWN_ATTR_SIZE bytes.

    Returns:
        0 on success, or an error number directly. Destroy the initialized
        object after its last use to release resources.
    """
    return external_call["posix_spawnattr_init", c_int](attr)


@inline(.always)
def posix_spawnattr_destroy(attr: VoidPtr) -> c_int:
    """Releases resources held by a spawn attribute object.

    Args:
        attr: Successfully initialized posix_spawnattr_t no longer used by a
            spawn call. The caller owns its storage.

    Returns:
        0 on success, or an error number directly. Reinitialize before reuse.
    """
    return external_call["posix_spawnattr_destroy", c_int](attr)


@inline(.always)
def posix_spawnattr_setflags(attr: VoidPtr, flags: c_short) -> c_int:
    """Selects which attributes are applied when spawning a child.

    Args:
        attr: Initialized writable spawn attribute object.
        flags: Bitwise combination of supported POSIX_SPAWN_* flags. This
            replaces the previous flags; setters alone do not enable them.

    Returns:
        0 on success, or an error number directly.
    """
    return external_call["posix_spawnattr_setflags", c_int](attr, flags)


@inline(.always)
def posix_spawnattr_setpgroup(attr: VoidPtr, pgroup: c_int) -> c_int:
    """Sets the child's requested process group in a spawn attribute object.

    Args:
        attr: Initialized writable spawn attribute object; enable
            POSIX_SPAWN_SETPGROUP in its flags to apply this value.
        pgroup: Nonnegative process group ID; 0 makes the child's PID its
            process group ID. Joining a group must satisfy setpgid rules.

    Returns:
        0 on success, or an error number directly. The parent is unaffected.
    """
    return external_call["posix_spawnattr_setpgroup", c_int](attr, pgroup)


@inline(.always)
def posix_spawnattr_setsigmask(attr: VoidPtr, sigmask: VoidPtr) -> c_int:
    """Copies the child's requested signal mask into a spawn attribute object.

    Args:
        attr: Initialized writable spawn attribute object; enable
            POSIX_SPAWN_SETSIGMASK in its flags to apply this value.
        sigmask: Readable initialized sigset_t; the set is copied during the
            call and need not outlive it. Blocked signals are set members.

    Returns:
        0 on success, or an error number directly. The parent's mask is unchanged.
    """
    return external_call["posix_spawnattr_setsigmask", c_int](attr, sigmask)


@inline(.always)
def posix_spawnattr_setsigdefault(attr: VoidPtr, sigdefault: VoidPtr) -> c_int:
    """Copies signals to reset to default handling when spawning a child.

    Args:
        attr: Initialized writable spawn attribute object; enable
            POSIX_SPAWN_SETSIGDEF in its flags to apply this value.
        sigdefault: Readable initialized sigset_t identifying signals to reset.
            The set is copied during the call and need not outlive it.

    Returns:
        0 on success, or an error number directly. Parent dispositions are unchanged.
    """
    return external_call["posix_spawnattr_setsigdefault", c_int](
        attr, sigdefault
    )
