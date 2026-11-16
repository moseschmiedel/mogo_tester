"""Finding the test files selected by command-line operands."""

from std.os.path import islink
from std.pathlib import Path

from ..fs.paths import clean


comptime RECURSIVE_HINT = " (use --recursive to search subdirectories)"
"""Appended to discovery diagnostics when nested files were not searched."""


struct Discovery(Movable):
    """The test files selected by the operands, plus the directory operands
    that contributed none."""

    var paths: List[Path]
    var empty_dirs: List[Path]

    def __init__(out self):
        self.paths = List[Path]()
        self.empty_dirs = List[Path]()


def discover_tests(
    test_paths: List[Path], recursive: Bool = False, out result: Discovery
) raises:
    """Returns the .mojo files selected by test_paths.

    Directory operands contribute their sorted top-level .mojo files, or with
    recursive set, every .mojo file below them sorted by path. Symlinked
    subdirectories are not followed. File operands are kept in operand order
    and must have a .mojo extension.

    Raises:
        Error: If an operand does not exist, a file operand is not a .mojo
            file, or no test files are found at all.
    """
    result = Discovery()
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
            var found = discover_tests_in_dir(test_path, recursive)
            if len(found) == 0:
                result.empty_dirs.append(test_path)
            result.paths.extend(found^)
            continue
        if test_path.suffix() != ".mojo":
            raise Error("test file ", test_path, " must have .mojo extension")
        result.paths.append(test_path)

    if len(result.paths) == 0:
        var operands = List[String]()
        for test_path in test_paths:
            operands.append(String(test_path))
        var hint = "" if recursive else RECURSIVE_HINT
        raise Error("no .mojo test files found in ", ", ".join(operands), hint)


def empty_dir_warning(dir: Path, recursive: Bool) -> String:
    """Returns the warning for a directory operand without test files."""
    var hint = "" if recursive else RECURSIVE_HINT
    return String("no .mojo files found in ", dir, hint)


def discover_tests_in_dir(
    dir: Path, recursive: Bool = False, out result: List[Path]
) raises:
    """Returns the sorted .mojo files in dir, including nested ones when
    recursive is set."""
    result = List[Path]()
    _collect(dir, recursive, result)
    sort(Span(result))


def _collect(dir: Path, recursive: Bool, mut result: List[Path]) raises:
    var entries: List[Path]
    try:
        entries = dir.listdir()
    except e:
        raise Error("discover tests in ", dir, ": ", e)
    for entry in entries:
        var path = clean(dir / entry.path)
        if path.is_dir():
            if recursive and not islink(path):
                _collect(path, recursive, result)
            continue
        if path.suffix() == ".mojo":
            result.append(path)
