"""Outcome and options of a child process run."""

from ..posix.env import Environment


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
    """Execution options: PTY-backed output, and environment variables that
    override the inherited environment."""

    var fake_tty: Bool
    var env: Environment

    @staticmethod
    def plain() -> Self:
        return Self(False, Environment())

    @staticmethod
    def tty() -> Self:
        return Self(True, Environment())
