"""Filesystem helpers built on `std.pathlib.Path`."""

from std.os import getenv, remove, rmdir
from std.os.path import islink
from std.pathlib import Path

from ..posix import libc
from ..posix.cffi import addr


def clean(path: Path) -> Path:
    """Returns the shortest equivalent path by lexical processing, like Go's
    filepath.Clean: collapses separators and resolves `.` and `..`.

    `Path` keeps paths verbatim, so this normalizes operands such as
    `./test/` before they are joined, displayed, or hashed.
    """
    var text = path.path
    if text == "":
        return Path(".")
    var rooted = text.startswith("/")
    var parts = List[String]()
    for raw in path.parts():
        var part = String(raw)
        if part == "" or part == ".":
            continue
        if part == "..":
            if len(parts) > 0 and parts[len(parts) - 1] != "..":
                _ = parts.pop()
            elif not rooted:
                parts.append(part)
            continue
        parts.append(part)
    var joined = "/".join(parts)
    if rooted:
        return Path("/" + joined)
    if joined == "":
        return Path(".")
    return Path(joined)


def package_name(path: Path) -> String:
    """Returns the importable package name for a package directory, which
    is its last path element."""
    return clean(path).name()


def make_temp_dir(prefix: String) raises -> Path:
    """Creates a unique mode-0700 directory under `$TMPDIR` (or /tmp).

    Raises:
        Error: If mkdtemp(3) fails.
    """
    var root = String(getenv("TMPDIR", "/tmp").rstrip("/"))
    var template = String(root, "/", prefix, "XXXXXXXX")
    var bytes = List[UInt8](template.as_bytes())
    bytes.append(0)
    if libc.mkdtemp(addr(bytes)) == 0:
        raise Error("mkdtemp ", template, ": ", libc.strerror(libc.errno()))
    # mkdtemp fills in the template in place.
    return Path(String(unsafe_from_utf8=Span(bytes)[0 : len(bytes) - 1]))


def remove_all(path: Path) raises:
    """Removes path and everything below it. Symlinks are removed, not
    followed."""
    if islink(path) or (path.exists() and not path.is_dir()):
        remove(path)
        return
    if not path.exists():
        return
    for entry in path.listdir():
        remove_all(path / entry.path)
    rmdir(path)
