"""Finding the test files selected by command-line operands."""

from std.pathlib import Path

from ..fs.paths import clean


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
