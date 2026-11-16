"""Ctrl-C (SIGINT) handling."""

from std.ffi import c_int

from . import libc
from .cffi import vp


def _sigint_disposition() -> Int:
    """Returns the handler address currently installed for SIGINT."""
    var action = List[Int](length=libc.SIGACTION_SIZE // 8, fill=0)
    if libc.sigaction(libc.SIGINT, vp(0), vp(Int(action.unsafe_ptr()))) != 0:
        return 0
    # Both the glibc and Darwin `struct sigaction` start with the handler.
    return action[0]


def _on_sigint(sig: c_int) abi("C"):
    """One-shot SIGINT handler: records the signal by switching SIGINT's
    disposition to ignored. sigaction is async-signal-safe and the action
    lives on the stack, so this does not allocate."""
    var action = Array[Int, libc.SIGACTION_SIZE // 8](fill=0)
    action[0] = libc.SIG_IGN
    _ = libc.sigaction(libc.SIGINT, vp(Int(action.unsafe_ptr())), vp(0))


struct InterruptGuard(Movable):
    """Turns SIGINT into an observable event so Ctrl-C can be handled with
    `interrupted()` instead of terminating the process immediately.

    The Mojo runtime starts threads before `main`, so blocking the signal
    with sigprocmask would not cover them, and Mojo has no global variables
    for a handler to set. The handler instead stores the event in the kernel:
    it sets SIGINT's disposition to ignored, which `interrupted()` queries.
    Further Ctrl-C presses are ignored after the first one.
    """

    var seen: Bool

    def __init__(out self):
        self.seen = False
        var handler: libc.SignalHandler = _on_sigint
        _ = libc.signal(libc.SIGINT, handler)

    def interrupted(mut self) -> Bool:
        """Reports whether SIGINT has been received since construction."""
        if not self.seen:
            self.seen = _sigint_disposition() == libc.SIG_IGN
        return self.seen
