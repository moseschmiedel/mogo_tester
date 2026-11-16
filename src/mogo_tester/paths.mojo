"""Test discovery, artifact naming, and filesystem helpers built on
`std.pathlib.Path`."""

from std.os import getenv, remove, rmdir
from std.os.path import islink
from std.pathlib import Path

from . import libc
from .cffi import addr
from .sha256 import hex_encode, sha256


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


def discover_tests(test_paths: List[Path], out result: List[Path]) raises:
    """Returns the .mojo files selected by test_paths.

    Directory operands contribute their sorted top-level .mojo files; nested
    directories are not searched. File operands are kept in operand order and
    must have a .mojo extension.

    Raises:
        Error: If an operand does not exist, a file operand is not a .mojo
            file, or no test files are found at all.
    """
    result = List[Path]()
    for test_path in test_paths:
        if not test_path.exists():
            raise Error(
                "discover tests in ",
                test_path,
                ": stat ",
                test_path,
                ": no such file or directory",
            )
        if test_path.is_dir():
            result.extend(discover_tests_in_dir(test_path))
            continue
        if test_path.suffix() != ".mojo":
            raise Error("test file ", test_path, " must have .mojo extension")
        result.append(test_path)

    if len(result) == 0:
        var operands = List[String]()
        for test_path in test_paths:
            operands.append(String(test_path))
        raise Error("no .mojo test files found in ", ", ".join(operands))


def discover_tests_in_dir(dir: Path, out result: List[Path]) raises:
    """Returns the sorted top-level .mojo files in dir."""
    var entries: List[Path]
    try:
        entries = dir.listdir()
    except e:
        raise Error("discover tests in ", dir, ": ", e)
    result = List[Path]()
    for entry in entries:
        var path = clean(dir / entry.path)
        if path.suffix() == ".mojo" and not path.is_dir():
            result.append(path)
    sort(Span(result))


def sanitize_binary_name(name: String, out result: String):
    """Replaces characters outside `[A-Za-z0-9._-]` with underscores."""
    result = String("")
    for cp in name.codepoints():
        var c = Int(cp)
        if (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord("_")
            or c == ord(".")
        ):
            result += String(cp)
        else:
            result += "_"
    if result == "":
        result = "test"


def binary_path_for(artifact_dir: Path, path: Path) -> Path:
    """Derives a filesystem-safe artifact path for a source file. A hash of
    the full path keeps identical file names from colliding."""
    var name = path.name()
    var stem = String(
        name[byte = 0 : name.byte_length() - path.suffix().byte_length()]
    )
    var digest = hex_encode(sha256(String(path).as_bytes()))
    return artifact_dir / (
        sanitize_binary_name(stem) + "-" + String(digest[byte=0:10])
    )


def precompiled_package_path_for(artifact_dir: Path, path: Path) -> Path:
    """Returns the .mojoc path whose file name becomes the importable package
    name."""
    return artifact_dir / (package_name(path) + ".mojoc")


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
