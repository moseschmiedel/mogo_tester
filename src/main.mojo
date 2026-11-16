"""Mogo-tester compiles and runs top-level Mojo test files.

Release builds inject version metadata with `-D MOGO_VERSION=...`,
`-D MOGO_COMMIT=...`, and `-D MOGO_DATE=...`.
"""

from std.sys import argv, exit
from std.sys.defines import get_defined_string

from mogo_tester.app import format_version, log, run
from mogo_tester.report import Output


def resolved_version() -> String:
    """Returns the --version text from compile-time defines."""
    return format_version(
        String(get_defined_string["MOGO_VERSION", "dev"]()),
        String(get_defined_string["MOGO_COMMIT", "unknown"]()),
        String(get_defined_string["MOGO_DATE", "unknown"]()),
    )


def main():
    var args = List[String]()
    var raw = argv()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))

    var out = Output()
    try:
        run(args, resolved_version(), out)
    except e:
        log("ERROR", "application failed", [("error", String(e))])
        exit(1)
