"""Top-level application flow and logging."""

from .args import Config, parse_args, usage
from .asan import locate_asan_runtime
from .libc import InterruptGuard, local_timestamp, make_temp_dir, write_all
from .paths import discover_tests, remove_all
from .report import Output
from .runner import precompile_modules, run_tests


def _log_value(value: String) -> String:
    """Quotes a log value when it contains spaces, quotes, or `=`."""
    if value == "":
        return '""'
    var needs_quotes = False
    for cp in value.codepoints():
        var c = Int(cp)
        if c <= 0x20 or c == ord('"') or c == ord("=") or c == 0x7F:
            needs_quotes = True
            break
    if not needs_quotes:
        return value
    var escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )
    return '"' + escaped + '"'


def log(level: String, message: String, attrs: List[Tuple[String, String]]):
    """Writes one logfmt record to stderr."""
    var line = String(
        "time=",
        local_timestamp(),
        " level=",
        level,
        " msg=",
        _log_value(message),
    )
    for attr in attrs:
        line += " " + attr[0] + "=" + _log_value(attr[1])
    write_all(2, line + "\n")


def format_version(version: String, commit: String, date: String) -> String:
    """Joins the version with commit and date metadata, omitting empty or
    unknown fields."""
    var text = version
    if commit != "" and commit != "unknown":
        text += " commit=" + commit
    if date != "" and date != "unknown":
        text += " date=" + date
    return text^


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

    var artifact_dir: String
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
                log(
                    "ERROR",
                    "remove artifact directory",
                    [("path", artifact_dir), ("error", String(e))],
                )


def _run_in(
    mut cfg: Config,
    paths: List[String],
    artifact_dir: String,
    mut out: Output,
    mut guard: InterruptGuard,
) raises:
    if len(cfg.precompile_paths) > 0:
        precompile_modules(cfg, artifact_dir, out, guard)
        cfg.precompile_import_dir = artifact_dir

    if guard.interrupted():
        raise Error("interrupted")

    log(
        "INFO",
        "running mojo tests",
        [
            ("paths", "[" + " ".join(cfg.test_paths) + "]"),
            ("count", String(len(paths))),
            ("parallel", String(cfg.parallel)),
        ],
    )

    var outcome = run_tests(cfg, paths, artifact_dir, out, guard)
    var summary = outcome[0].copy()

    if cfg.keep_artifacts:
        out.write("artifacts: " + artifact_dir + "\n")

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
