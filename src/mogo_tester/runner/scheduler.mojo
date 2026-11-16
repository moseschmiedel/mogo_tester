"""The parallel compile/run scheduler and its progress reporting."""

from std.os import isatty
from std.pathlib import Path
from std.time import monotonic

from ..cli.args import Config
from ..posix.signals import InterruptGuard
from ..process.child import Child
from ..process.result import CommandOptions, ProcessResult
from ..process.run import poll_children
from ..report.blocks import (
    print_result_block,
    print_skipped,
    print_summary,
)
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
from ..suite.doctest import Doctest, remap_locations
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


@fieldwise_init
struct TestSource(Copyable, Movable):
    """One program to compile and run.

    `path` is the file passed to `mojo build`; `label` names it in progress
    and result output. For a doctest, `path` is the generated program and
    `doctest` maps its compiler diagnostics back to the documentation.
    """

    var path: Path
    var label: Path
    var doctest: Optional[Doctest]

    @staticmethod
    def file(path: Path) -> Self:
        return Self(path, path, None)


def _remap_doctest_output(mut result: ProcessResult, source: TestSource):
    if not source.doctest:
        return
    ref doctest = source.doctest.value()
    var generated = String(source.path)
    result.stdout = remap_locations(result.stdout, generated, doctest)
    result.stderr = remap_locations(result.stderr, generated, doctest)


struct Job(Movable):
    """One test file moving through compile and run stages."""

    var result: FileResult
    var source: TestSource
    var stage: Int
    var use_asan: Bool

    def __init__(
        out self,
        var result: FileResult,
        var source: TestSource,
        stage: Int,
        use_asan: Bool,
    ):
        self.result = result^
        self.source = source^
        self.stage = stage
        self.use_asan = use_asan


def run_tests(
    cfg: Config,
    sources: List[TestSource],
    skipped: List[Path],
    artifact_dir: Path,
    mut out: Output,
    mut guard: InterruptGuard,
) -> Tuple[RunSummary, Bool]:
    """Compiles and runs sources with up to `cfg.parallel` concurrent jobs.

    Skipped paths are reported as `SKIP` lines first and counted in the
    summary, but not compiled or run.

    Returns the summary and whether the run was interrupted. On interrupt,
    running children are killed and no further files are started. A doctest
    that could not be generated is reported as a compile failure without
    invoking `mojo build`.
    """
    var start = monotonic()
    var live = (not out.capture) and isatty(1)
    var colors = Colors(not cfg.no_color)
    var reporter = Reporter(len(sources), colors, live)
    for path in skipped:
        print_skipped(out, path, colors)
    reporter.summary.skipped = len(skipped)
    var jobs = List[Job]()
    var children = List[Child]()
    var next = 0
    var cancelled = False

    while True:
        if not cancelled and guard.interrupted():
            cancelled = True
            for c in range(len(children)):
                children[c].kill()

        while (
            not cancelled and len(jobs) < cfg.parallel and next < len(sources)
        ):
            var source = sources[next].copy()
            next += 1
            if source.doctest and source.doctest.value().error != "":
                reporter.progress.update(source.label, STAGE_COMPILING)
                reporter.progress.update(source.label, STAGE_DONE)
                reporter.on_result(
                    out,
                    FileResult(
                        source.label,
                        List[String](),
                        ProcessResult.failed(
                            "doctest: " + source.doctest.value().error
                        ),
                        ProcessResult.empty(),
                        False,
                        Path(""),
                    ),
                )
                continue
            var path = source.path
            var markers = read_markers(path)
            var use_asan = cfg.asan and not markers.skip_asan
            var binary_path = binary_path_for(artifact_dir, path)
            var command = compile_command(
                cfg, path, binary_path, markers, use_asan
            )
            reporter.on_progress(out, source.label, STAGE_COMPILING)
            children.append(Child(command, CommandOptions.plain()))
            jobs.append(
                Job(
                    FileResult(
                        source.label,
                        command^,
                        ProcessResult.empty(),
                        ProcessResult.empty(),
                        False,
                        binary_path,
                    ),
                    source^,
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
                _remap_doctest_output(finished, jobs[i].source)
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
