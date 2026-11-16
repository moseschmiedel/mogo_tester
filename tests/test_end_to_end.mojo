"""End-to-end tests for the built binary using a fake `mojo` on PATH.

The binary under test is `$MOGO_TESTER_BIN`, or `bin/mogo-tester`.
"""

from std.os import getenv, listdir, makedirs
from std.os.path import exists, realpath
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.fs.paths import make_temp_dir, remove_all
from mogo_tester.posix import libc
from mogo_tester.posix.env import Environment
from mogo_tester.process.child import Child
from mogo_tester.process.result import CommandOptions, ProcessResult
from mogo_tester.process.run import poll_children, run_command

comptime FAKE_MOJO = """#!/bin/sh
echo "$*" >> "$MOGO_FAKE_LOG"
cmd=$1
shift
out=""
src=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -I|-D|--sanitize|--external-libasan) shift 2 ;;
    -*) shift ;;
    *) src=$1; shift ;;
  esac
done
if [ "$cmd" = precompile ]; then
  if [ -f "$src/FAIL" ]; then echo "precompile broke" >&2; exit 4; fi
  if [ -f "$src/SLOW" ]; then sleep 30; fi
  : > "$out"
  exit 0
fi
if grep -q COMPILE_FAIL "$src"; then echo "fake compile error" >&2; exit 1; fi
{ echo '#!/bin/sh'; sed -n 's/^# RUN: //p' "$src"; } > "$out"
chmod +x "$out"
"""


struct Sandbox(Movable):
    var root: String
    var bin: String

    def __init__(out self) raises:
        self.root = String(make_temp_dir("mogo-cli-"))
        makedirs(self.root + "/fake")
        makedirs(self.root + "/tmp")
        makedirs(self.root + "/t")
        write_file(self.root + "/fake/mojo", FAKE_MOJO)
        _ = run_command(
            ["chmod", "+x", self.root + "/fake/mojo"], CommandOptions.plain()
        )
        self.bin = realpath(getenv("MOGO_TESTER_BIN", "bin/mogo-tester"))

    def add_test(self, name: String, body: String) raises:
        write_file(self.root + "/t/" + name, body)

    def options(self) -> CommandOptions:
        var env = Environment()
        env.set("PATH", self.root + "/fake:" + getenv("PATH"))
        env.set("MOGO_FAKE_LOG", self.root + "/log")
        env.set("TMPDIR", self.root + "/tmp")
        return CommandOptions(False, env^)

    def run(self, args: List[String]) -> ProcessResult:
        var argv: List[String] = [self.bin]
        for arg in args:
            argv.append(arg)
        return run_command(argv, self.options())

    def log(self) -> String:
        try:
            with open(self.root + "/log", "r") as f:
                return f.read()
        except:
            return ""

    def artifact_dirs(self) raises -> List[String]:
        return listdir(self.root + "/tmp")

    def __deinit__(deinit self):
        try:
            remove_all(self.root)
        except:
            pass


def write_file(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def test_reports_pass_compile_failure_and_run_failure() raises:
    var box = Sandbox()
    box.add_test("a_pass.mojo", "# RUN: echo hello\n")
    box.add_test("b_compile.mojo", "# COMPILE_FAIL\n")
    box.add_test("c_run.mojo", "# RUN: echo boom\n# RUN: exit 2\n")
    var r = box.run(["--no-color", box.root + "/t"])
    assert_equal(r.exit_code, 1)
    assert_true(
        "Summary: total=3 passed=1 failed_compile=1 failed_run=1 elapsed="
        in r.stdout
    )
    assert_true(
        "compile stderr:\nfake compile error\nexit status 1\nrun:"
        " SKIPPED\nresult: FAIL"
        in r.stdout
    )
    assert_true("run: FAIL exit=2" in r.stdout)
    assert_true("run output:\nboom\nresult: FAIL" in r.stdout)
    assert_true("run output:\nhello\nresult: PASS" in r.stdout)
    assert_false("\x1b[" in r.stdout)
    assert_true("PROGRESS [3/3]\n" in r.stdout)
    assert_true(
        "ERROR::: application failed: test run failed: 1 compile failure(s),"
        " 1 run failure(s)"
        in r.stderr
    )
    assert_true("INFO::: running mojo tests paths=[" in r.stderr)
    assert_equal(len(box.artifact_dirs()), 0)


def test_runs_doctests_without_test_paths() raises:
    var box = Sandbox()
    makedirs(box.root + "/docs/nested")
    makedirs(box.root + "/docs/.hidden")
    write_file(
        box.root + "/docs/guide.md",
        (
            '```mojo {doctest="ok" global=true}\n'
            "# RUN: echo doc-ok\n"
            "```\n"
            '```mojo {doctest="ok"}\n'
            "print(1)\n"
            "```\n"
            '```mojo {doctest="clash" global=true}\n'
            "def main():\n"
            "    pass\n"
            "```\n"
            '```mojo {doctest="clash"}\n'
            "main()\n"
            "```\n"
        ),
    )
    write_file(
        box.root + "/docs/nested/lib.mojo",
        (
            'def f():\n    """Doc.\n\n    ```mojo {doctest="broken"'
            ' global=true}\n    # COMPILE_FAIL\n    ```\n    """\n'
            "    pass\n"
        ),
    )
    write_file(
        box.root + "/docs/.hidden/skip.md",
        '```mojo {doctest="hidden" global=true}\n# COMPILE_FAIL\n```\n',
    )
    var r = box.run(["--no-color", "--doctests", box.root + "/docs"])
    assert_equal(r.exit_code, 1)
    assert_true(
        "Summary: total=3 passed=1 failed_compile=2 failed_run=0" in r.stdout
    )
    var docs = box.root + "/docs"
    assert_true("=== " + docs + "/guide.md:1#ok ===" in r.stdout)
    assert_true("run output:\ndoc-ok\nresult: PASS" in r.stdout)
    assert_true("=== " + docs + "/guide.md:7#clash ===" in r.stdout)
    assert_true("doctest: global blocks define `def main`" in r.stdout)
    assert_true("=== " + docs + "/nested/lib.mojo:4#broken ===" in r.stdout)
    assert_false("hidden" in r.stdout)
    var log = box.log()
    assert_true("/doctests/guide.md_ok-" in log)
    assert_false("clash" in log)
    assert_equal(len(box.artifact_dirs()), 0)


def test_doctests_combine_with_tests_and_require_doctests() raises:
    var box = Sandbox()
    makedirs(box.root + "/docs")
    box.add_test("a.mojo", "# RUN: true\n")
    write_file(box.root + "/docs/empty.md", "No doctests here.\n")
    var none = box.run(["--doctests", box.root + "/docs", box.root + "/t"])
    assert_equal(none.exit_code, 1)
    assert_true("no doctests found in " in none.stderr)

    write_file(
        box.root + "/docs/one.md",
        '```mojo {doctest="x" global=true}\n# RUN: true\n```\n',
    )
    var both = box.run(
        ["--no-color", "--doctests", box.root + "/docs", box.root + "/t"]
    )
    assert_equal(both.exit_code, 0)
    assert_true("Summary: total=2 passed=2" in both.stdout)

    var missing = box.run(["--doctests", box.root + "/nope"])
    assert_equal(missing.exit_code, 1)
    assert_true("no such file or directory" in missing.stderr)


def test_all_passing_exits_zero_with_colors() raises:
    var box = Sandbox()
    box.add_test("ok.mojo", "# RUN: echo fine\n")
    var r = box.run([box.root + "/t/ok.mojo", "--mojo-build-args", "-I src"])
    assert_equal(r.exit_code, 0)
    assert_true("\x1b[32mPASS\x1b[0m" in r.stdout)
    assert_true("build -I src -o " in box.log())


def test_binary_sees_tty_and_build_does_not() raises:
    var box = Sandbox()
    box.add_test(
        "tty.mojo",
        (
            "# RUN: [ -t 1 ] && echo out-tty\n# RUN: [ -t 2 ] && echo err-tty"
            " >&2\n# RUN: true\n"
        ),
    )
    var r = box.run(["--no-color", box.root + "/t"])
    assert_equal(r.exit_code, 0)
    assert_true("run output:\nout-tty\nerr-tty\n" in r.stdout)
    assert_true("compile stdout:\ncompile stderr:\n" in r.stdout)


def test_precompiles_modules_before_building_tests() raises:
    var box = Sandbox()
    makedirs(box.root + "/pkg/shared")
    box.add_test("a.mojo", "# RUN: true\n")
    var r = box.run(
        [
            "--no-color",
            "--precompile",
            box.root + "/pkg/shared/",
            box.root + "/t",
        ]
    )
    assert_equal(r.exit_code, 0)
    var lines = box.log().splitlines()
    assert_equal(len(lines), 2)
    assert_true(lines[0].startswith("precompile -o "))
    assert_true(lines[0].endswith("/shared.mojoc " + box.root + "/pkg/shared/"))
    assert_true(
        lines[1].startswith("build -I " + box.root + "/tmp/mogo-tester-")
    )
    assert_true(
        "=== precompile "
        + box.root
        + "/pkg/shared/ ===\nprecompile command: mojo precompile -o "
        in r.stdout
    )


def test_rejects_duplicate_precompile_basenames() raises:
    var box = Sandbox()
    box.add_test("a.mojo", "# RUN: true\n")
    var r = box.run(
        [
            "--precompile",
            "x/shared",
            "--precompile",
            "y/shared",
            box.root + "/t",
        ]
    )
    assert_equal(r.exit_code, 1)
    assert_true(
        'precompile package basename "shared" is used by both x/shared and'
        " y/shared"
        in r.stderr
    )
    assert_equal(box.log(), "")


def test_stops_when_precompile_fails() raises:
    var box = Sandbox()
    makedirs(box.root + "/pkg")
    write_file(box.root + "/pkg/FAIL", "")
    box.add_test("a.mojo", "# RUN: true\n")
    var r = box.run(
        ["--no-color", "--precompile", box.root + "/pkg", box.root + "/t"]
    )
    assert_equal(r.exit_code, 1)
    assert_true(
        "precompile module " + box.root + "/pkg: exit status 4" in r.stderr
    )
    assert_true("precompile output:\nprecompile broke\n" in r.stdout)
    assert_false("build" in box.log())
    assert_equal(len(box.artifact_dirs()), 0)


def test_keep_artifacts_retains_directory() raises:
    var box = Sandbox()
    box.add_test("a.mojo", "# RUN: true\n")
    var r = box.run(["--keep-artifacts", box.root + "/t"])
    assert_equal(r.exit_code, 0)
    var dirs = box.artifact_dirs()
    assert_equal(len(dirs), 1)
    assert_true(
        String("artifacts: ", box.root, "/tmp/", dirs[0], "\n") in r.stdout
    )
    var artifact_dir = box.root + "/tmp/" + dirs[0]
    assert_equal(len(listdir(artifact_dir)), 1)
    _ = box^  # Keep the sandbox alive until the directory has been checked.


def test_honors_parallel_limit() raises:
    var box = Sandbox()
    for name in ["a.mojo", "b.mojo", "c.mojo"]:
        box.add_test(name, "# RUN: sleep 0.1\n")
    var r = box.run(["--parallel", "1", box.root + "/t"])
    assert_equal(r.exit_code, 0)
    for line in r.stdout.splitlines():
        if "PROGRESS" in line:
            assert_true(line.count(".mojo") <= 1, String(line))


def test_test_with_background_process_finishes() raises:
    var box = Sandbox()
    box.add_test("bg.mojo", "# RUN: echo started\n# RUN: sleep 30 &\n")
    var r = box.run(["--no-color", box.root + "/t"])
    assert_equal(r.exit_code, 0)
    assert_true("run output:\nstarted\nresult: PASS" in r.stdout)
    assert_true(r.duration_ns < 20_000_000_000, "run waited for the descendant")


def test_runs_with_low_descriptor_limit() raises:
    var box = Sandbox()
    box.add_test("a.mojo", "# RUN: echo ok\n")
    var argv: List[String] = [
        "sh",
        "-c",
        'ulimit -n 64 && exec "$0" "$@"',
        box.bin,
        "--no-color",
        box.root + "/t",
    ]
    var r = run_command(argv, box.options())
    assert_equal(r.exit_code, 0, r.stdout + r.stderr)
    assert_true("result: PASS" in r.stdout)
    _ = box^  # Keep the sandbox alive until the child has finished.


def test_version_and_help() raises:
    var box = Sandbox()
    var version = box.run(["--version"])
    assert_equal(version.exit_code, 0)
    assert_true(version.stdout.startswith("mogo-tester "))
    var help = box.run(["--help"])
    assert_equal(help.exit_code, 0)
    assert_true(
        help.stdout.startswith(
            "Usage: mogo-tester [OPTION...] [TEST-PATH...]\n"
        )
    )


def test_interrupt_kills_tests_and_cleans_up() raises:
    var box = Sandbox()
    box.add_test("slow.mojo", "# RUN: sleep 30\n")
    var children = List[Child]()
    children.append(
        Child([box.bin, "--no-color", box.root + "/t"], box.options())
    )
    var polls = 0
    var sent = False
    while poll_children(children, 100):
        polls += 1
        if not sent and polls >= 10:
            _ = libc.kill(children[0].pid, libc.SIGINT)
            sent = True
        assert_true(polls < 100, "mogo-tester did not stop after SIGINT")
    var r = children[0].result()
    assert_equal(r.exit_code, 1)
    assert_true("ERROR::: application failed: interrupted" in r.stderr)
    assert_true("run: FAIL exit=-1" in r.stdout)
    assert_true("signal: killed" in r.stdout)
    assert_equal(len(box.artifact_dirs()), 0)


def test_interrupt_during_precompile() raises:
    var box = Sandbox()
    makedirs(box.root + "/pkg")
    write_file(box.root + "/pkg/SLOW", "")
    box.add_test("a.mojo", "# RUN: true\n")
    var children = List[Child]()
    children.append(
        Child(
            [box.bin, "--precompile", box.root + "/pkg", box.root + "/t"],
            box.options(),
        )
    )
    var polls = 0
    while poll_children(children, 100):
        polls += 1
        if polls == 10:
            _ = libc.kill(children[0].pid, libc.SIGINT)
        assert_true(polls < 100, "mogo-tester did not stop after SIGINT")
    var r = children[0].result()
    assert_equal(r.exit_code, 1)
    assert_true("ERROR::: application failed: interrupted" in r.stderr)
    assert_false("build" in box.log())
    assert_equal(len(box.artifact_dirs()), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
