"""Report destination and ANSI styling."""


struct Output(Movable):
    """Destination for report text: stdout, or an in-memory buffer."""

    var capture: Bool
    var buffer: String

    def __init__(out self, capture: Bool = False):
        self.capture = capture
        self.buffer = ""

    def write(mut self, text: String):
        if self.capture:
            self.buffer += text
        else:
            print(text, end="", flush=True)


@fieldwise_init
struct Colors(Copyable, Movable):
    """ANSI styling that degrades to plain text when disabled."""

    var enabled: Bool

    def wrap(self, code: String, value: String) -> String:
        if not self.enabled:
            return value
        return code + value + "\x1b[0m"

    def header(self, value: String) -> String:
        return self.wrap("\x1b[36;1m", value)

    def summary(self, value: String) -> String:
        return self.wrap("\x1b[36;1m", value)

    def label(self, value: String) -> String:
        return self.wrap("\x1b[1m", value)

    def pass_(self, value: String) -> String:
        return self.wrap("\x1b[32m", value)

    def fail(self, value: String) -> String:
        return self.wrap("\x1b[31m", value)

    def skip(self, value: String) -> String:
        return self.wrap("\x1b[33m", value)

    def dim(self, value: String) -> String:
        return self.wrap("\x1b[2m", value)
