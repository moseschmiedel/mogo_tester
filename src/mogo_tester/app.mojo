"""Top-level application flow and logging."""

from std.logger import Level, Logger
from std.os import makedirs
from std.pathlib import Path
from std.sys import stderr

from .cli.args import Config, parse_args, usage
from .fs.paths import make_temp_dir, remove_all
from .posix.signals import InterruptGuard
from .report.output import Output
from .runner.precompile import precompile_modules
from .runner.scheduler import TestSource, run_tests
from .suite.artifacts import sanitize_binary_name
from .suite.discovery import discover_tests
from .suite.doctest import discover_doctest_files, scan_doctests
from .fs.sha256 import hex_encode, sha256
from .toolchain.asan import locate_asan_runtime


comptime AppLogger = Logger[Level.INFO]
"""Logger for diagnostics on stderr; report output goes to stdout."""


def logger() -> AppLogger:
    """Returns the stderr logger."""
    return AppLogger(fd=stderr)


def format_version(
    version: String, commit: String, date: String, out text: String
):
    """Joins the version with commit and date metadata, omitting empty or
    unknown fields."""
    text = version
    if commit != "" and commit != "unknown":
        text += " commit=" + commit
    if date != "" and date != "unknown":
        text += " date=" + date


def run(args: List[String], version: String, mut out: Output) raises:
    """Runs the application. Raises on usage errors, setup errors, test
    failures, and interrupts."""
    var cfg: Config
    try:
        cfg = parse_args(args)
    except e:
        if e.show_usage:
            out.write(e.message + "\n")
            out.write(usage(Config().parallel))
        raise Error(e.message)

    if cfg.show_help:
        out.write(usage(Config().parallel))
        return

    if cfg.show_version:
        out.write("mogo-tester " + version + "\n")
        return

    if cfg.asan:
        cfg.asan_runtime = locate_asan_runtime()

    var guard = InterruptGuard()

    var paths = List[Path]()
    if len(cfg.test_paths) > 0:
        paths = discover_tests(cfg.test_paths)
    var doctest_files = List[Path]()
    if len(cfg.doctest_paths) > 0:
        doctest_files = discover_doctest_files(cfg.doctest_paths)

    var artifact_dir: Path
    try:
        artifact_dir = make_temp_dir("mogo-tester-")
    except e:
        raise Error("create artifact directory: ", e)

    try:
        var sources = List[TestSource]()
        for path in paths:
            sources.append(TestSource.file(path))
        if len(doctest_files) > 0:
            generate_doctests(doctest_files, artifact_dir, sources)
            if len(sources) == len(paths):
                var operands = List[String]()
                for doctest_path in cfg.doctest_paths:
                    operands.append(String(doctest_path))
                raise Error("no doctests found in ", ", ".join(operands))
        _run_in(cfg, sources, artifact_dir, out, guard)
    finally:
        if not cfg.keep_artifacts:
            try:
                remove_all(artifact_dir)
            except e:
                logger().error(
                    "remove artifact directory", artifact_dir, String(e)
                )


def generate_doctests(
    files: List[Path], artifact_dir: Path, mut sources: List[TestSource]
) raises:
    """Writes one program per doctest in files below artifact_dir and
    appends it to sources.

    Doctests that could not be generated are appended without writing a
    file, so the runner reports them as failures.

    Raises:
        Error: If a file cannot be read or a program cannot be written.
    """
    var dir = artifact_dir / "doctests"
    makedirs(dir, exist_ok=True)
    for file in files:
        var text: String
        try:
            text = file.read_text()
        except e:
            raise Error("read doctests in ", file, ": ", e)
        for doctest in scan_doctests(String(file), text):
            var label = doctest.label()
            var digest = hex_encode(sha256(label.as_bytes()))
            var path = dir / (
                sanitize_binary_name(file.name() + "_" + doctest.name)
                + "-"
                + String(digest[byte=0:10])
                + ".mojo"
            )
            if doctest.error == "":
                path.write_text(doctest.code)
            sources.append(TestSource(path, Path(label), doctest.copy()))


def _run_in(
    mut cfg: Config,
    sources: List[TestSource],
    artifact_dir: Path,
    mut out: Output,
    mut guard: InterruptGuard,
) raises:
    if len(cfg.precompile_paths) > 0:
        precompile_modules(cfg, artifact_dir, out, guard)
        cfg.precompile_import_dir = artifact_dir

    if guard.interrupted():
        raise Error("interrupted")

    var operands = List[String]()
    for test_path in cfg.test_paths:
        operands.append(String(test_path))
    var doctest_operands = List[String]()
    for doctest_path in cfg.doctest_paths:
        doctest_operands.append(String(doctest_path))
    logger().info(
        "running mojo tests",
        String("paths=[", " ".join(operands), "]"),
        String("doctests=[", " ".join(doctest_operands), "]"),
        String("count=", len(sources)),
        String("parallel=", cfg.parallel),
    )

    var outcome = run_tests(cfg, sources, artifact_dir, out, guard)
    var summary = outcome[0].copy()

    if cfg.keep_artifacts:
        out.write(String("artifacts: ", artifact_dir, "\n"))

    if outcome[1]:
        raise Error("interrupted")

    if summary.failed():
        raise Error(
            "test run failed: ",
            summary.failed_compile,
            " compile failure(s), ",
            summary.failed_run,
            " run failure(s)",
        )
