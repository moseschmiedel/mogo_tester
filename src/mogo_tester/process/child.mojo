"""A spawned child process and the output it produces."""

from std.ffi import c_int
from std.pathlib import Path
from std.time import monotonic

from ..posix.env import Environment
from ..posix.fd import PollSet, close_fd, make_pipe, read_fd
from ..posix.libc import SIGKILL
from ..posix.pty import open_pty
from ..posix.spawn import (
    SpawnRequest,
    kill_group,
    look_path,
    signal_name,
    spawn,
    wait_pid,
)
from .result import CommandOptions, ProcessResult


comptime MAX_DRAIN_READS = 256
"""Upper bound on reads after exit, so a descendant that keeps writing to the
inherited output cannot stall the run."""


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

        var file: Path
        try:
            file = look_path(argv[0])
        except e:
            self.spawn_error = String(e)
            return
        var env = Environment.current()
        env.update(options.env)

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

    def try_reap(mut self) -> Bool:
        """Collects the exit status without blocking, independently of
        whether the output descriptors have reached EOF.

        Returns:
            Whether the child's exit status is known.
        """
        if self.spawn_error != "":
            return False
        if not self.status:
            self.status = wait_pid(self.pid)
        return Bool(self.status)

    def finish_output(mut self, mut buf: List[UInt8]):
        """Drains output that is already buffered and closes the descriptors.
        Call this only once the child has exited.

        Background processes started by the child can inherit its stdout and
        stderr and keep them open indefinitely, so this does not wait for
        EOF; output those descendants write later is discarded.
        """
        if len(self.fds) == 0:
            return
        for _ in range(MAX_DRAIN_READS):
            var open_fds = List[c_int]()
            var slots = List[Int]()
            for i in range(len(self.fds)):
                if self.fds[i] >= 0:
                    open_fds.append(self.fds[i])
                    slots.append(i)
            if len(open_fds) == 0:
                break
            var poll_set = PollSet(open_fds)
            if poll_set.wait(0) <= 0:
                break
            for k in range(len(open_fds)):
                if poll_set.ready(k):
                    self.read_ready(slots[k], buf)
        for fd in self.fds:
            if fd >= 0:
                close_fd(fd)
        self.fds.clear()

    def result(self, out result: ProcessResult):
        """Builds the final result. Only meaningful once `done()`."""
        var duration = Int(monotonic() - self.start_ns)
        if self.spawn_error != "":
            result = ProcessResult.failed(self.spawn_error)
            result.duration_ns = duration
            return
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
        result = ProcessResult(
            stdout^,
            String(from_utf8_lossy=Span(self.stderr)),
            self.combined,
            exit_code,
            duration,
            error^,
        )


def _spawn_error(argv: List[String], e: Error) -> String:
    return String("fork/exec ", argv[0], ": ", e)


def normalize_pty_output(output: String) -> String:
    """Converts CRLF produced by PTYs to LF."""
    return output.replace("\r\n", "\n")
