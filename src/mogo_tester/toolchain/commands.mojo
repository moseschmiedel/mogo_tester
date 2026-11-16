"""Command lines for `mojo build` and the options for running test binaries."""

from std.pathlib import Path

from ..cli.args import Config
from ..process.result import CommandOptions
from ..suite.markers import SourceMarkers


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
