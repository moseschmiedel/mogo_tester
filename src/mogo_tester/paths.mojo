"""Path helpers, test discovery, and artifact naming."""

from std.os import listdir, remove, rmdir
from std.os.path import exists, isdir, islink

from .sha256 import hex_encode, sha256


def clean_path(path: String) -> String:
    """Returns the shortest equivalent path by lexical processing, like Go's
    filepath.Clean: collapses separators and resolves `.` and `..`."""
    if path == "":
        return "."
    var rooted = path.startswith("/")
    var parts = List[String]()
    for raw in path.split("/"):
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
        return "/" + joined
    if joined == "":
        return "."
    return joined^


def join_path(dir: String, name: String) -> String:
    """Joins two path elements and cleans the result."""
    if dir == "":
        return clean_path(name)
    return clean_path(dir + "/" + name)


def base_name(path: String) -> String:
    """Returns the last element of path, like Go's filepath.Base."""
    if path == "":
        return "."
    var trimmed = String(path.rstrip("/"))
    if trimmed == "":
        return "/"
    var index = trimmed.rfind("/")
    if index < 0:
        return trimmed^
    return String(trimmed[byte = index + 1 : trimmed.byte_length()])


def extension(path: String) -> String:
    """Returns the suffix starting at the final dot of the last element."""
    var base = base_name(path)
    var index = base.rfind(".")
    if index < 0:
        return ""
    return String(base[byte = index : base.byte_length()])


def discover_tests(test_paths: List[String]) raises -> List[String]:
    """Returns the .mojo files selected by test_paths.

    Directory operands contribute their sorted top-level .mojo files; nested
    directories are not searched. File operands are kept in operand order and
    must have a .mojo extension.
    """
    var paths = List[String]()
    for test_path in test_paths:
        if not exists(test_path):
            raise Error(
                "discover tests in ",
                test_path,
                ": stat ",
                test_path,
                ": no such file or directory",
            )
        if isdir(test_path):
            for p in discover_tests_in_dir(test_path):
                paths.append(p)
            continue
        if not base_name(test_path).endswith(".mojo"):
            raise Error("test file ", test_path, " must have .mojo extension")
        paths.append(test_path)

    if len(paths) == 0:
        raise Error("no .mojo test files found in ", ", ".join(test_paths))
    return paths^


def discover_tests_in_dir(dir: String) raises -> List[String]:
    """Returns sorted top-level .mojo files in dir."""
    var names: List[String]
    try:
        names = listdir(dir)
    except e:
        raise Error("discover tests in ", dir, ": ", e)
    var paths = List[String]()
    for name in names:
        var path = join_path(dir, name)
        if name.endswith(".mojo") and not isdir(path):
            paths.append(path)
    sort(Span(paths))
    return paths^


def sanitize_binary_name(name: String) -> String:
    """Replaces characters outside [A-Za-z0-9._-] with underscores."""
    var out = String("")
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
            out += String(cp)
        else:
            out += "_"
    if out == "":
        return "test"
    return out^


def binary_path_for(artifact_dir: String, path: String) -> String:
    """Derives a filesystem-safe artifact path for a source file. A hash of
    the full path keeps identical basenames from colliding."""
    var base = base_name(path)
    var ext = extension(path)
    if ext != "":
        var stem = String(
            base[byte = 0 : base.byte_length() - ext.byte_length()]
        )
        base = stem^
    var digest = hex_encode(sha256(path.as_bytes()))
    var name = sanitize_binary_name(base) + "-" + String(digest[byte=0:10])
    return join_path(artifact_dir, name)


def precompiled_package_path_for(artifact_dir: String, path: String) -> String:
    """Returns the .mojoc path whose basename becomes the importable package
    name."""
    return join_path(artifact_dir, base_name(clean_path(path)) + ".mojoc")


def remove_all(path: String) raises:
    """Removes path and everything below it. Symlinks are removed, not
    followed."""
    if islink(path) or (exists(path) and not isdir(path)):
        remove(path)
        return
    if not exists(path):
        return
    for name in listdir(path):
        remove_all(join_path(path, name))
    rmdir(path)
