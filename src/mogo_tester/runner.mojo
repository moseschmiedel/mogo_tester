"""Precompilation and the parallel compile/run scheduler."""

from std.os import isatty

from .args import Config
from .asan import (
    asan_reported,
    file_skips_asan,
    file_skips_debug,
    mark_asan_failure,
)
from .libc import InterruptGuard
from .paths import (
    base_name,
    binary_path_for,
    clean_path,
    precompiled_package_path_for,
)
from .process import (
    Child,
    CommandOptions,
    ProcessResult,
    poll_children,
    run_command,
)
from .report import (
    Colors,
    FileResult,
    Output,
    ProgressTracker,
    RunSummary,
    STAGE_COMPILING,
    STAGE_DONE,
    STAGE_RUNNING,
    clear_progress,
    print_precompile_block,
    print_progress,
    print_result_block,
    print_summary,
)
from std.time import monotonic


comptime POLL_INTERVAL_MS = 100


struct Reporter(Movable):
    """Renders progress updates and result blocks as jobs advance."""

    var progress: ProgressTracker
    var summary: RunSummary
    var colors: Colors
    var live: Bool
    var visible: Bool

    def __init__(out self, total: Int, colors: Colors, live: Bool):
        self.progress = ProgressTracker(total)
        self.summary = RunSummary()
        self.colors = colors.copy()
        self.live = live
        self.visible = False

    def on_progress(mut self, mut out: Output, path: String, stage: Int):
        self.progress.update(path, stage)
        print_progress(out, self.progress, self.live)
        self.visible = self.live

    def on_result(mut self, mut out: Output, result: FileResult):
        self.summary.add(result)
        if self.live and self.visible:
            clear_progress(out)
            self.visible = False
        print_result_block(out, result, self.colors)
        if self.live and self.progress.completed < self.progress.total:
            print_progress(out, self.progress, True)
            self.visible = True

    def finish(mut self, mut out: Output, elapsed_ns: Int) -> RunSummary:
        if self.live and self.visible:
            clear_progress(out)
        self.summary.elapsed_ns = elapsed_ns
        print_summary(out, self.summary, self.colors)
        return self.summary.copy()


struct Job(Movable):
    """One test file moving through compile and run stages."""

    var result: FileResult
    var stage: Int
    var use_asan: Bool

    def __init__(out self, var result: FileResult, stage: Int, use_asan: Bool):
        self.result = result^
        self.stage = stage
        self.use_asan = use_asan


def mojo_build_args_for_file(args: List[String], path: String) -> List[String]:
    """Returns build arguments for path, dropping `-g` for files with the
    `# SKIP_DEBUG` marker."""
    if not file_skips_debug(path):
        return args.copy()
    var filtered = List[String]()
    for arg in args:
        if arg != "-g":
            filtered.append(arg)
    return filtered^


def compile_command(
    cfg: Config, path: String, binary_path: String, use_asan: Bool
) -> List[String]:
    """Builds the `mojo build` argv for one test file."""
    var argv: List[String] = ["mojo", "build"]
    for arg in mojo_build_args_for_file(cfg.mojo_build_args, path):
        argv.append(arg)
    if cfg.precompile_import_dir != "":
        argv.append("-I")
        argv.append(cfg.precompile_import_dir)
    if use_asan:
        argv.append("--sanitize")
        argv.append("address")
        for arg in cfg.asan_runtime.build_args:
            argv.append(arg)
    argv.append("-o")
    argv.append(binary_path)
    argv.append(path)
    return argv^


def run_options(cfg: Config, use_asan: Bool) -> CommandOptions:
    """Returns PTY-backed options for a test binary, with the ASAN preload
    variable when needed."""
    var options = CommandOptions.tty()
    if use_asan:
        options.env.append(
            cfg.asan_runtime.preload_var + "=" + cfg.asan_runtime.lib_path
        )
    return options^


def precompile_modules(
    cfg: Config,
    artifact_dir: String,
    mut out: Output,
    mut guard: InterruptGuard,
) raises:
    """Runs `mojo precompile` for each requested package before tests are
    built. The .mojoc basename must match the package basename because Mojo
    uses it as the import name, so duplicate basenames are rejected."""
    for i in range(len(cfg.precompile_paths)):
        var base = base_name(clean_path(cfg.precompile_paths[i]))
        for j in range(i):
            if base_name(clean_path(cfg.precompile_paths[j])) == base:
                raise Error(
                    'precompile package basename "',
                    base,
                    '" is used by both ',
                    cfg.precompile_paths[j],
                    " and ",
                    cfg.precompile_paths[i],
                )

    var colors = Colors(not cfg.no_color)
    for path in cfg.precompile_paths:
        var command: List[String] = [
            "mojo",
            "precompile",
            "-o",
            precompiled_package_path_for(artifact_dir, path),
            path,
        ]
        var outcome = run_command(command, CommandOptions.tty(), guard)
        var result = outcome[0].copy()
        print_precompile_block(out, path, command, result, colors)
        if outcome[1]:
            raise Error("interrupted")
        if not result.succeeded():
            if result.error != "":
                raise Error("precompile module ", path, ": ", result.error)
            raise Error(
                "precompile module ",
                path,
                " failed with exit code ",
                result.exit_code,
            )


def run_tests(
    cfg: Config,
    paths: List[String],
    artifact_dir: String,
    mut out: Output,
    mut guard: InterruptGuard,
) -> Tuple[RunSummary, Bool]:
    """Compiles and runs paths with up to `cfg.parallel` concurrent jobs.

    Returns the summary and whether the run was interrupted. On interrupt,
    running children are killed and no further files are started.
    """
    var start = monotonic()
    var live = (not out.capture) and isatty(1)
    var reporter = Reporter(len(paths), Colors(not cfg.no_color), live)
    var jobs = List[Job]()
    var children = List[Child]()
    var next = 0
    var cancelled = False

    while True:
        if not cancelled and guard.interrupted():
            cancelled = True
            for c in range(len(children)):
                children[c].kill()

        while not cancelled and len(jobs) < cfg.parallel and next < len(paths):
            var path = paths[next]
            next += 1
            var use_asan = cfg.asan and not file_skips_asan(path)
            var binary_path = binary_path_for(artifact_dir, path)
            var command = compile_command(cfg, path, binary_path, use_asan)
            reporter.on_progress(out, path, STAGE_COMPILING)
            children.append(Child(command, CommandOptions.plain()))
            jobs.append(
                Job(
                    FileResult(
                        path,
                        command^,
                        ProcessResult.empty(),
                        ProcessResult.empty(),
                        False,
                        binary_path,
                    ),
                    STAGE_COMPILING,
                    use_asan,
                )
            )

        if len(jobs) == 0:
            break

        _ = poll_children(children, POLL_INTERVAL_MS)

        var i = 0
        while i < len(jobs):
            if not children[i].done():
                i += 1
                continue
            var finished = children[i].result()
            if jobs[i].stage == STAGE_COMPILING:
                jobs[i].result.compile = finished^
                if jobs[i].result.compile.succeeded() and not cancelled:
                    jobs[i].result.did_run = True
                    jobs[i].stage = STAGE_RUNNING
                    reporter.on_progress(
                        out, jobs[i].result.path, STAGE_RUNNING
                    )
                    children[i] = Child(
                        [jobs[i].result.binary_path],
                        run_options(cfg, jobs[i].use_asan),
                    )
                    i += 1
                    continue
            else:
                if jobs[i].use_asan and asan_reported(finished):
                    finished = mark_asan_failure(finished^)
                jobs[i].result.run = finished^
            reporter.on_progress(out, jobs[i].result.path, STAGE_DONE)
            var job = jobs.pop(i)
            _ = children.pop(i)
            reporter.on_result(out, job.result)

    var summary = reporter.finish(out, Int(monotonic() - start))
    return (summary^, cancelled)
