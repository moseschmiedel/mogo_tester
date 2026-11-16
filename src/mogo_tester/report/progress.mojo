"""The live progress line that lists files being compiled and run."""

from std.pathlib import Path

from .output import Output


comptime STAGE_DONE = 0


comptime STAGE_COMPILING = 1


comptime STAGE_RUNNING = 2


struct ProgressTracker(Movable):
    """Active stage per file plus the completed/total counter."""

    var total: Int
    var completed: Int
    var paths: List[Path]
    var stages: List[Int]

    def __init__(out self, total: Int):
        self.total = total
        self.completed = 0
        self.paths = List[Path]()
        self.stages = List[Int]()

    def update(mut self, path: Path, stage: Int):
        """Records the latest stage for path; leaving the active set counts
        the file as completed."""
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                if stage == STAGE_DONE:
                    _ = self.paths.pop(i)
                    _ = self.stages.pop(i)
                    self.completed += 1
                else:
                    self.stages[i] = stage
                return
        if stage != STAGE_DONE:
            self.paths.append(path)
            self.stages.append(stage)

    def paths_for(self, stage: Int, out result: List[String]):
        """Returns the sorted file names of files currently in stage."""
        result = List[String]()
        for i in range(len(self.paths)):
            if self.stages[i] == stage:
                result.append(self.paths[i].name())
        sort(Span(result))


def format_progress(progress: ProgressTracker) -> String:
    """Renders active compile and run stages and the completed/total count."""
    var parts = List[String]()
    var compiling = progress.paths_for(STAGE_COMPILING)
    if len(compiling) > 0:
        parts.append("C " + ", ".join(compiling))
    var running = progress.paths_for(STAGE_RUNNING)
    if len(running) > 0:
        parts.append("R " + ", ".join(running))
    parts.append(
        String("PROGRESS [", progress.completed, "/", progress.total, "]")
    )
    return ", ".join(parts)


def print_progress(mut out: Output, progress: ProgressTracker, live: Bool):
    """Writes an in-place terminal progress line, or a plain line when the
    output is not a terminal."""
    var line = format_progress(progress)
    if live:
        out.write("\r\x1b[2K" + line)
    else:
        out.write(line + "\n")


def clear_progress(mut out: Output):
    """Erases the current terminal progress line."""
    out.write("\r\x1b[2K")
