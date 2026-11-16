"""Text formatting for commands, durations, and captured output."""

from ..process.result import ProcessResult


def format_command(args: List[String]) -> String:
    """Renders argv for display; execution never goes through a shell."""
    var quoted = List[String](capacity=len(args))
    for arg in args:
        quoted.append(quote_arg(arg))
    return " ".join(quoted)


def quote_arg(arg: String) -> String:
    """Applies POSIX single-quote escaping when arg needs it."""
    if arg == "":
        return "''"
    comptime special = "'\"\\$&;()<>|*?[]{}!\n\t"
    var needs_quotes = False
    for cp in arg.codepoints():
        var value = Int(cp)
        if value <= 0x20 or (value < 0x80 and String(cp) in special):
            needs_quotes = True
            break
    if not needs_quotes:
        return arg
    return "'" + arg.replace("'", "'\\''") + "'"


def stderr_with_error(result: ProcessResult) -> String:
    """Appends the execution error to stderr when the process failed."""
    if result.error == "":
        return result.stderr
    if result.stderr == "":
        return result.error
    if result.stderr.endswith("\n"):
        return result.stderr + result.error
    return result.stderr + "\n" + result.error


def combined_output_with_error(result: ProcessResult) -> String:
    """Returns PTY output, or the execution error if there was no output."""
    if result.error == "" or result.stdout != "":
        return result.stdout
    return result.error


def _frac(value: Int, precision: Int) -> Tuple[String, Int]:
    """Formats the low `precision` decimal digits of value as a fraction
    without trailing zeros; returns the text and value with them removed."""
    var v = value
    var digits = String("")
    var printing = False
    for _ in range(precision):
        var digit = v % 10
        printing = printing or digit != 0
        if printing:
            digits = String(digit) + digits
        v //= 10
    if printing:
        digits = "." + digits
    return (digits^, v)


def format_duration(ns: Int) -> String:
    """Formats nanoseconds like Go's time.Duration.String, e.g. 1.5s,
    12.345ms, 2m3.5s."""
    if ns == 0:
        return "0s"
    var negative = ns < 0
    var u = -ns if negative else ns
    var sign = "-" if negative else ""
    if u < 1_000_000_000:
        if u < 1000:
            return String(sign, u, "ns")
        var unit: String
        var precision: Int
        if u < 1_000_000:
            unit = "µs"
            precision = 3
        else:
            unit = "ms"
            precision = 6
        var parts = _frac(u, precision)
        return String(sign, parts[1], parts[0], unit)

    var parts = _frac(u, 9)
    var seconds = parts[1]
    var text = String(seconds % 60, parts[0], "s")
    var minutes = seconds // 60
    if minutes > 0:
        text = String(minutes % 60, "m") + text
        var hours = minutes // 60
        if hours > 0:
            text = String(hours, "h") + text
    return sign + text
