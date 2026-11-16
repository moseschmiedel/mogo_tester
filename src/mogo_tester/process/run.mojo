"""Driving child processes to completion.

Children are advanced by a single-threaded poll(2) loop rather than threads:
callers repeatedly `poll_children` until every child reports `done()`.
"""

from std.ffi import c_int

from ..posix.fd import PollSet
from ..posix.signals import InterruptGuard
from .child import Child
from .result import CommandOptions, ProcessResult


comptime READ_CHUNK = 65536
"""Bytes read from one descriptor per poll iteration."""


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
        if len(children[c].fds) == 0 or children[c].status:
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
        if children[c].try_reap():
            children[c].finish_output(buf)
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
