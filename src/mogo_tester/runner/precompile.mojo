"""Precompiling shared Mojo packages before tests are built."""

from std.pathlib import Path

from ..cli.args import Config
from ..fs.paths import package_name
from ..posix.signals import InterruptGuard
from ..process.result import CommandOptions
from ..process.run import run_command
from ..report.blocks import print_precompile_block
from ..report.output import Colors, Output
from ..suite.artifacts import precompiled_package_path_for


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
