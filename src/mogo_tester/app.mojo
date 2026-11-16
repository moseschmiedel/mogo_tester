"""Top-level application flow and logging."""

from std.logger import Level, Logger
from std.pathlib import Path
from std.sys import stderr

from .cli.args import Config, parse_args, usage
from .fs.paths import make_temp_dir, remove_all
from .posix.signals import InterruptGuard
from .report.output import Output
from .runner.precompile import precompile_modules
from .runner.scheduler import run_tests
from .suite.discovery import discover_tests
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

    var paths = discover_tests(cfg.test_paths)

    var artifact_dir: Path
    try:
        artifact_dir = make_temp_dir("mogo-tester-")
    except e:
        raise Error("create artifact directory: ", e)

    try:
        _run_in(cfg, paths, artifact_dir, out, guard)
    finally:
        if not cfg.keep_artifacts:
            try:
                remove_all(artifact_dir)
            except e:
                logger().error(
                    "remove artifact directory", artifact_dir, String(e)
                )


def _run_in(
    mut cfg: Config,
    paths: List[Path],
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
    logger().info(
        "running mojo tests",
        String("paths=[", " ".join(operands), "]"),
        String("count=", len(paths)),
        String("parallel=", cfg.parallel),
    )

    var outcome = run_tests(cfg, paths, artifact_dir, out, guard)
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
