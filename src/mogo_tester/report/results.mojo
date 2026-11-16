"""Per-file results and run totals."""

from std.pathlib import Path

from ..process.result import ProcessResult


@fieldwise_init
struct FileResult(Copyable, Movable):
    """Compile and run outcome for one test source file."""

    var path: Path
    var compile_cmd: List[String]
    var compile: ProcessResult
    var run: ProcessResult
    var did_run: Bool
    var binary_path: Path

    def passed(self) -> Bool:
        return (
            self.compile.succeeded() and self.did_run and self.run.succeeded()
        )

    def compile_failed(self) -> Bool:
        return not self.compile.succeeded()

    def run_failed(self) -> Bool:
        return self.compile.succeeded() and (
            not self.did_run or not self.run.succeeded()
        )


@fieldwise_init
struct RunSummary(Copyable, Movable):
    """Aggregate counters for a whole run."""

    var total: Int
    var passed: Int
    var failed_compile: Int
    var failed_run: Int
    var elapsed_ns: Int

    def __init__(out self):
        self = Self(0, 0, 0, 0, 0)

    def failed(self) -> Bool:
        return self.failed_compile > 0 or self.failed_run > 0

    def add(mut self, result: FileResult):
        self.total += 1
        if result.passed():
            self.passed += 1
        elif result.compile_failed():
            self.failed_compile += 1
        elif result.run_failed():
            self.failed_run += 1
