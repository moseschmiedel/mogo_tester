"""The parallel compile/run scheduler and its progress reporting."""

from std.os import isatty
from std.pathlib import Path
from std.time import monotonic

from ..cli.args import Config
from ..posix.signals import InterruptGuard
from ..process.child import Child
from ..process.result import CommandOptions, ProcessResult
from ..process.run import poll_children
from ..report.blocks import print_result_block, print_summary
from ..report.output import Colors, Output
from ..report.progress import (
    ProgressTracker,
    STAGE_COMPILING,
    STAGE_DONE,
    STAGE_RUNNING,
    clear_progress,
    print_progress,
)
from ..report.results import FileResult, RunSummary
from ..suite.artifacts import binary_path_for
from ..suite.markers import read_markers
from ..toolchain.asan import asan_reported, mark_asan_failure
from ..toolchain.commands import compile_command, run_options


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
