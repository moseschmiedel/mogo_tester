"""Per-file compiler settings in Mojo test sources."""

from std.pathlib import Path

comptime HEADER_CHUNK = 512
comptime NEWLINE = Byte(ord("\n"))
comptime BUILD_ARGS_MARKER = "# MOJO_BUILD_ARGS:"


@fieldwise_init
struct SourceMarkers(Copyable, Movable):
    """Markers found in the comment header of a test source file."""

    var skip_asan: Bool
    """`# SKIP_ASAN`: build and run this file without AddressSanitizer."""
    var skip_debug: Bool
    """`# SKIP_DEBUG`: drop the exact `-g` build argument for this file."""
    var build_args: List[String]
    """Arguments from `# MOJO_BUILD_ARGS:` lines, in source order."""

    def __init__(out self):
        self = Self(False, False, List[String]())


def read_markers(path: Path, out result: SourceMarkers):
    """Reads the markers from the comment header of the file at path.

    The comment header is the run of lines at the top of the file that are
    blank or start with `#`. Only that header is read, so the cost does not
    grow with the file size. Unreadable files have no markers.
    """
    result = SourceMarkers()
    # Keep bytes until a line is complete so a chunk boundary cannot split a
    # UTF-8 sequence before decoding.
    var pending = List[Byte]()
    try:
        with open(path, "r") as f:
            while True:
                var chunk = f.read_bytes(HEADER_CHUNK)
                var at_eof = len(chunk) < HEADER_CHUNK
                pending.extend(Span(chunk))
                var start = 0
                for i in range(len(pending)):
                    if pending[i] != NEWLINE:
                        continue
                    var line = String(from_utf8_lossy=Span(pending)[start:i])
                    if not _apply_header_line(line, result):
                        return
                    start = i + 1
                var rest = List[Byte](Span(pending)[start:])
                if at_eof:
                    _ = _apply_header_line(String(from_utf8_lossy=rest), result)
                    return
                pending = rest^
    except:
        return


def _apply_header_line(raw: String, mut markers: SourceMarkers) -> Bool:
    """Apply a line and return whether it belongs to the comment header."""
    var line = String(raw.strip())
    if line != "" and not line.startswith("#"):
        return False
    _apply_marker(line, markers)
    return True


def _apply_marker(line: String, mut markers: SourceMarkers):
    """Apply one comment-header line to the file's settings."""
    if line.startswith(BUILD_ARGS_MARKER):
        var args = String(line[byte = BUILD_ARGS_MARKER.byte_length() :])
        for field in args.split():
            markers.build_args.append(String(field))
        return
    if "# SKIP_ASAN" in line:
        markers.skip_asan = True
    if "# SKIP_DEBUG" in line:
        markers.skip_debug = True
