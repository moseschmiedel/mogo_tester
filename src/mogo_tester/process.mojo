"""Child process execution with captured output.

Children are driven by a poll(2) loop rather than threads: each `Child` owns
its output descriptors, and callers repeatedly `poll_children` until every
child reports `done()`.
"""

from std.ffi import c_int
from std.time import monotonic

from std.os import getenv

from .libc import (
    is_executable,
    InterruptGuard,
    PollSet,
    SIGKILL,
    SpawnRequest,
    close_fd,
    current_environment,
    kill_group,
    make_pipe,
    open_pty,
    read_fd,
    signal_name,
    spawn,
    wait_pid,
)

comptime READ_CHUNK = 65536


@fieldwise_init
struct ProcessResult(Copyable, Movable):
    """Captured output and exit information for one finished process.

    `error` is empty when the process exited with status zero; otherwise it
    describes the failure, such as `exit status 1` or `signal: killed`.
    When `combined` is set, `stdout` holds interleaved stdout and stderr
    captured through a PTY.
    """

    var stdout: String
    var stderr: String
    var combined: Bool
    var exit_code: Int
    var duration_ns: Int
    var error: String

    @staticmethod
    def empty() -> Self:
        return Self("", "", False, 0, 0, "")

    @staticmethod
    def failed(var message: String) -> Self:
        return Self("", "", False, -1, 0, message^)

    def succeeded(self) -> Bool:
        """Reports whether the process exited zero without an error."""
        return self.error == "" and self.exit_code == 0


@fieldwise_init
struct CommandOptions(Copyable, Movable):
    """Execution options: PTY-backed output and extra environment entries."""

    var fake_tty: Bool
    var env: List[String]

    @staticmethod
    def plain() -> Self:
        return Self(False, List[String]())

    @staticmethod
    def tty() -> Self:
        return Self(True, List[String]())


struct Child(Movable):
    """A running (or finished) child process and its captured output."""

    var pid: c_int
    var fds: List[c_int]
    var stdout: List[UInt8]
    var stderr: List[UInt8]
    var combined: Bool
    var start_ns: Int
    var status: Optional[c_int]
    var spawn_error: String

    def __init__(out self, argv: List[String], options: CommandOptions):
        """Spawns argv. Spawn failures are recorded rather than raised so the
        child reports `done()` immediately with a failed result."""
        self.pid = 0
        self.fds = List[c_int]()
        self.stdout = List[UInt8]()
        self.stderr = List[UInt8]()
        self.combined = False
        self.start_ns = monotonic()
        self.status = None
        self.spawn_error = ""

        var file: String
        try:
            file = look_path(argv[0])
        except e:
            self.spawn_error = String(e)
            return
        var env = _merge_env(current_environment(), options.env)

        if options.fake_tty:
            try:
                var pty = open_pty()
                var request = SpawnRequest(
                    file, argv.copy(), env.copy(), pty[1], pty[1]
                )
                try:
                    self.pid = spawn(request)
                except e:
                    close_fd(pty[0])
                    close_fd(pty[1])
                    self.spawn_error = _spawn_error(argv, e)
                    return
                close_fd(pty[1])
                self.fds.append(pty[0])
                self.combined = True
                return
            except:
                pass  # PTYs unsupported: fall back to pipes.

        try:
            var out = make_pipe()
            var err_pipe: Tuple[c_int, c_int]
            try:
                err_pipe = make_pipe()
            except e:
                close_fd(out[0])
                close_fd(out[1])
                raise e^
            var request = SpawnRequest(
                file, argv.copy(), env^, out[1], err_pipe[1]
            )
            try:
                self.pid = spawn(request)
            except e:
                close_fd(out[0])
                close_fd(out[1])
                close_fd(err_pipe[0])
                close_fd(err_pipe[1])
                self.spawn_error = _spawn_error(argv, e)
                return
            close_fd(out[1])
            close_fd(err_pipe[1])
            self.fds.append(out[0])
            self.fds.append(err_pipe[0])
        except e:
            self.spawn_error = String(e)

    def done(self) -> Bool:
        """Reports whether the child has been reaped and its output drained."""
        if self.spawn_error != "":
            return True
        return len(self.fds) == 0 and Bool(self.status)

    def kill(mut self):
        """Sends SIGKILL to a still-running child and its process group."""
        if self.spawn_error == "" and not self.status:
            kill_group(self.pid, SIGKILL)

    def read_ready(mut self, index: Int, mut buf: List[UInt8]):
        """Reads available data from fds[index], closing it at EOF."""
        var n = read_fd(self.fds[index], buf)
        if n > 0:
            if not self.combined and index == 1:
                self.stderr.extend(Span(buf)[0:n])
            else:
                self.stdout.extend(Span(buf)[0:n])
            return
        # EOF, or EIO once a PTY's slave side has been closed.
        close_fd(self.fds[index])
        self.fds[index] = -1

    def compact(mut self):
        """Drops closed descriptors while preserving stdout/stderr roles."""
        var all_closed = True
        for fd in self.fds:
            if fd >= 0:
                all_closed = False
        if all_closed:
            self.fds.clear()

    def try_reap(mut self, block: Bool):
        """Collects the exit status once all output has been drained."""
        if self.spawn_error != "" or self.status or len(self.fds) > 0:
            return
        self.status = wait_pid(self.pid, block)

    def result(self) -> ProcessResult:
        """Builds the final result. Only meaningful once `done()`."""
        var duration = Int(monotonic() - self.start_ns)
        if self.spawn_error != "":
            var r = ProcessResult.failed(self.spawn_error)
            r.duration_ns = duration
            return r^
        var status = Int(self.status.value())
        var exit_code: Int
        var error = String("")
        if (status & 0x7F) == 0:
            exit_code = (status >> 8) & 0xFF
            if exit_code != 0:
                error = String("exit status ", exit_code)
        else:
            exit_code = -1
            error = "signal: " + signal_name(status & 0x7F)
        var stdout = String(from_utf8_lossy=Span(self.stdout))
        if self.combined:
            stdout = normalize_pty_output(stdout)
        return ProcessResult(
            stdout^,
            String(from_utf8_lossy=Span(self.stderr)),
            self.combined,
            exit_code,
            duration,
            error^,
        )


def _spawn_error(argv: List[String], e: Error) -> String:
    return String("fork/exec ", argv[0], ": ", e)


def look_path(name: String) raises -> String:
    """Resolves name like a shell would: names containing a slash are used
    as-is, others are searched in the directories of $PATH.

    Raises:
        Error: If no executable file is found.
    """
    if "/" in name:
        return name
    var path = getenv("PATH")
    for raw in path.split(":"):
        var dir = String(raw)
        if dir == "":
            dir = "."
        var candidate = dir + "/" + name
        if is_executable(candidate):
            return candidate^
    raise Error('exec: "', name, '": executable file not found in $PATH')


def _merge_env(base: List[String], extra: List[String]) -> List[String]:
    """Appends extra KEY=VALUE entries, replacing existing keys."""
    var result = List[String]()
    for entry in base:
        var key = _env_key(entry)
        var overridden = False
        for e in extra:
            if _env_key(e) == key:
                overridden = True
        if not overridden:
            result.append(entry)
    for e in extra:
        result.append(e)
    return result^


def _env_key(entry: String) -> String:
    var index = entry.find("=")
    if index < 0:
        return entry
    return String(entry[byte=0:index])


def normalize_pty_output(output: String) -> String:
    """Converts CRLF produced by PTYs to LF."""
    return output.replace("\r\n", "\n")


def poll_children(mut children: List[Child], timeout_ms: Int) -> Bool:
    """Waits up to timeout_ms for output or exits and advances every child.

    Returns whether any child is still running.
    """
    var fds = List[c_int]()
    var owners = List[Int]()
    var slots = List[Int]()
    var waiting_for_exit = False
    for c in range(len(children)):
        if children[c].done():
            continue
        if len(children[c].fds) == 0:
            waiting_for_exit = True
        for i in range(len(children[c].fds)):
            if children[c].fds[i] >= 0:
                fds.append(children[c].fds[i])
                owners.append(c)
                slots.append(i)

    if len(fds) == 0 and not waiting_for_exit:
        for c in range(len(children)):
            if not children[c].done():
                return True
        return False

    var timeout = timeout_ms
    if waiting_for_exit:
        timeout = min(timeout, 10)
    var poll_set = PollSet(fds)
    _ = poll_set.wait(timeout)

    var buf = List[UInt8](length=READ_CHUNK, fill=0)
    for k in range(len(fds)):
        if poll_set.ready(k):
            children[owners[k]].read_ready(slots[k], buf)

    var running = False
    for c in range(len(children)):
        children[c].compact()
        children[c].try_reap(False)
        if not children[c].done():
            running = True
    return running


def run_command(argv: List[String], options: CommandOptions) -> ProcessResult:
    """Runs argv to completion and returns its captured result."""
    var children = List[Child]()
    children.append(Child(argv, options))
    while poll_children(children, 100):
        pass
    return children[0].result()


def run_command(
    argv: List[String], options: CommandOptions, mut guard: InterruptGuard
) -> Tuple[ProcessResult, Bool]:
    """Runs argv to completion, killing it if SIGINT arrives.

    Returns the captured result and whether the run was interrupted.
    """
    var children = List[Child]()
    children.append(Child(argv, options))
    var interrupted = False
    while poll_children(children, 100):
        if not interrupted and guard.interrupted():
            interrupted = True
            children[0].kill()
    return (children[0].result(), interrupted)
