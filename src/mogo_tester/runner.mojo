"""Precompilation and the parallel compile/run scheduler."""

from std.os import isatty
from std.pathlib import Path
from std.time import monotonic

from .args import Config
from .asan import asan_reported, mark_asan_failure
from .markers import SourceMarkers, read_markers
from .paths import binary_path_for, package_name, precompiled_package_path_for
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
from .signals import InterruptGuard


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

    def on_progress(mut self, mut out: Output, path: Path, stage: Int):
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


def mojo_build_args_for_file(
    args: List[String], markers: SourceMarkers, out result: List[String]
):
    """Returns the build arguments for one file, dropping `-g` when the file
    has the `# SKIP_DEBUG` marker."""
    result = List[String](capacity=len(args))
    for arg in args:
        if not (markers.skip_debug and arg == "-g"):
            result.append(arg)


def compile_command(
    cfg: Config,
    path: Path,
    binary_path: Path,
    markers: SourceMarkers,
    use_asan: Bool,
    out argv: List[String],
):
    """Builds the `mojo build` argv for one test file."""
    argv = ["mojo", "build"]
    argv.extend(mojo_build_args_for_file(cfg.mojo_build_args, markers))
    if cfg.precompile_import_dir:
        argv.append("-I")
        argv.append(String(cfg.precompile_import_dir.value()))
    if use_asan:
        argv.append("--sanitize")
        argv.append("address")
        argv.extend(cfg.asan_runtime.build_args.copy())
    argv.append("-o")
    argv.append(String(binary_path))
    argv.append(String(path))


def run_options(cfg: Config, use_asan: Bool, out options: CommandOptions):
    """Returns PTY-backed options for a test binary, with the ASAN preload
    variable when needed."""
    options = CommandOptions.tty()
    if use_asan:
        options.env.set(
            cfg.asan_runtime.preload_var, String(cfg.asan_runtime.lib_path)
        )


def precompile_modules(
    cfg: Config,
    artifact_dir: Path,
    mut out: Output,
    mut guard: InterruptGuard,
) raises:
    """Runs `mojo precompile` for each requested package before tests are
    built. The .mojoc file name must match the package name because Mojo
    uses it as the import name, so duplicate package names are rejected."""
    for i in range(len(cfg.precompile_paths)):
        var name = package_name(cfg.precompile_paths[i])
        for j in range(i):
            if package_name(cfg.precompile_paths[j]) == name:
                raise Error(
                    'precompile package basename "',
                    name,
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
            String(precompiled_package_path_for(artifact_dir, path)),
            String(path),
        ]
        var outcome = run_command(command, CommandOptions.tty(), guard)
        ref result = outcome[0]
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
    paths: List[Path],
    artifact_dir: Path,
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
            var markers = read_markers(path)
            var use_asan = cfg.asan and not markers.skip_asan
            var binary_path = binary_path_for(artifact_dir, path)
            var command = compile_command(
                cfg, path, binary_path, markers, use_asan
            )
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
                        [String(jobs[i].result.binary_path)],
                        run_options(cfg, jobs[i].use_asan),
                    )
                    i += 1
                    continue
            else:
                if jobs[i].use_asan and asan_reported(finished):
                    mark_asan_failure(finished)
                jobs[i].result.run = finished^
            reporter.on_progress(out, jobs[i].result.path, STAGE_DONE)
            var job = jobs.pop(i)
            _ = children.pop(i)
            reporter.on_result(out, job.result)

    var summary = reporter.finish(out, Int(monotonic() - start))
    return (summary^, cancelled)
