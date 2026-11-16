"""Starting, reaping, and signalling child processes."""

from std.ffi import c_int
from std.os import getenv
from std.pathlib import Path
from std.sys import CompilationTarget

from . import libc
from .cffi import CStringArray, addr, cstr
from .env import Environment


struct SpawnRequest(Movable):
    """Executable, arguments, environment, and output wiring for one child."""

    var file: Path
    var argv: List[String]
    var env: Environment
    var stdout_fd: c_int
    var stderr_fd: c_int

    def __init__(
        out self,
        file: Path,
        var argv: List[String],
        var env: Environment,
        stdout_fd: c_int,
        stderr_fd: c_int,
    ):
        self.file = file
        self.argv = argv^
        self.env = env^
        self.stdout_fd = stdout_fd
        self.stderr_fd = stderr_fd


def spawn(request: SpawnRequest) raises -> c_int:
    """Starts request.file with stdin from /dev/null and stdout and stderr
    attached to the requested descriptors.

    The child starts with an empty signal mask and default SIGINT handling,
    and leads a new process group so that `kill_group` also reaches any
    processes it starts.

    Returns:
        The child's process ID.

    Raises:
        Error: If posix_spawn fails.
    """
    var actions = List[UInt8](length=libc.SPAWN_FILE_ACTIONS_SIZE, fill=0)
    var attr = List[UInt8](length=libc.SPAWN_ATTR_SIZE, fill=0)
    var empty_set = List[UInt8](length=libc.SIGSET_SIZE, fill=0)
    var default_set = List[UInt8](length=libc.SIGSET_SIZE, fill=0)
    var dev_null = String("/dev/null")

    if libc.posix_spawn_file_actions_init(addr(actions)) != 0:
        raise Error("posix_spawn_file_actions_init failed")
    if libc.posix_spawnattr_init(addr(attr)) != 0:
        _ = libc.posix_spawn_file_actions_destroy(addr(actions))
        raise Error("posix_spawnattr_init failed")

    _ = libc.posix_spawn_file_actions_addopen(
        addr(actions), 0, cstr(dev_null), libc.O_RDONLY, 0
    )
    _ = libc.posix_spawn_file_actions_adddup2(
        addr(actions), request.stdout_fd, 1
    )
    _ = libc.posix_spawn_file_actions_adddup2(
        addr(actions), request.stderr_fd, 2
    )
    _ = libc.sigemptyset(addr(empty_set))
    _ = libc.posix_spawnattr_setsigmask(addr(attr), addr(empty_set))
    _ = libc.sigemptyset(addr(default_set))
    _ = libc.sigaddset(addr(default_set), libc.SIGINT)
    _ = libc.posix_spawnattr_setsigdefault(addr(attr), addr(default_set))
    _ = libc.posix_spawnattr_setpgroup(addr(attr), 0)
    _ = libc.posix_spawnattr_setflags(
        addr(attr),
        libc.POSIX_SPAWN_SETSIGMASK
        | libc.POSIX_SPAWN_SETSIGDEF
        | libc.POSIX_SPAWN_SETPGROUP,
    )

    var file = String(request.file)
    var argv = CStringArray(request.argv)
    var envp = CStringArray(request.env.entries())
    var pid = List[c_int](length=1, fill=0)
    var rc = libc.posix_spawn(
        addr(pid), cstr(file), addr(actions), addr(attr), argv.ptr(), envp.ptr()
    )
    _ = libc.posix_spawn_file_actions_destroy(addr(actions))
    _ = libc.posix_spawnattr_destroy(addr(attr))
    # Raw pointers do not keep their owners alive: hold every buffer that
    # posix_spawn or the file actions and attributes read until here.
    _ = file^
    _ = argv^
    _ = envp^
    _ = dev_null^
    _ = empty_set^
    _ = default_set^
    if rc != 0:
        raise Error(libc.strerror(rc))
    return pid[0]


def wait_pid(pid: c_int) -> Optional[c_int]:
    """Reaps pid without blocking.

    Returns:
        The raw wait status, or None if the process is still running or
        cannot be waited for.
    """
    var status = List[c_int](length=1, fill=0)
    while True:
        var rc = libc.waitpid(pid, addr(status), libc.WNOHANG)
        if rc == pid:
            return status[0]
        if rc == 0 or libc.errno() != libc.EINTR:
            return None


def kill_group(pid: c_int, signal: c_int):
    """Sends signal to the process group led by pid, ignoring errors."""
    _ = libc.kill(-pid, signal)


def is_executable(path: Path) -> Bool:
    """Reports whether path names an executable regular file."""
    if not path.is_file():
        return False
    var text = String(path)
    var rc = libc.access(cstr(text), libc.X_OK)
    _ = text^  # Keep the C string alive across the call.
    return rc == 0


def look_path(name: String) raises -> Path:
    """Resolves name like a shell: names containing a slash are used as-is,
    others are searched in the directories of `$PATH`.

    Raises:
        Error: If no executable file is found.
    """
    if "/" in name:
        return Path(name)
    for entry in getenv("PATH").split(":"):
        # An empty PATH entry means the current directory.
        var dir = Path(String(entry)) if entry.byte_length() > 0 else Path(".")
        var candidate = dir / name
        if is_executable(candidate):
            return candidate
    raise Error('exec: "', name, '": executable file not found in $PATH')


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
