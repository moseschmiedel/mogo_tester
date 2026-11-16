from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.asan import (
    asan_reported,
    file_skips_asan,
    file_skips_debug,
    glob_match,
    locate_asan_runtime_with,
    mark_asan_failure,
)
from mogo_tester.libc import SIGKILL, kill_group, make_temp_dir
from mogo_tester.paths import remove_all
from mogo_tester.process import (
    Child,
    CommandOptions,
    ProcessResult,
    poll_children,
    run_command,
)
from mogo_tester.runner import (
    compile_command,
    mojo_build_args_for_file,
    run_options,
)
from mogo_tester.args import Config


def write_file(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def write_script(path: String, content: String) raises:
    write_file(path, content)
    _ = run_command(["chmod", "+x", path], CommandOptions.plain())


def test_pipes_capture_stdout_stderr_and_exit_status() raises:
    var r = run_command(
        ["sh", "-c", "echo out; echo err >&2; exit 3"], CommandOptions.plain()
    )
    assert_equal(r.stdout, "out\n")
    assert_equal(r.stderr, "err\n")
    assert_false(r.combined)
    assert_equal(r.exit_code, 3)
    assert_equal(r.error, "exit status 3")


def test_tty_combines_output_and_is_a_terminal() raises:
    var r = run_command(
        [
            "sh",
            "-c",
            (
                "[ -t 1 ] && echo stdout-tty; [ -t 2 ] && echo stderr-tty >&2;"
                " [ -t 0 ] || echo stdin-not-tty"
            ),
        ],
        CommandOptions.tty(),
    )
    assert_true(r.combined)
    assert_equal(r.stdout, "stdout-tty\nstderr-tty\nstdin-not-tty\n")
    assert_true(r.succeeded())


def test_signal_and_missing_executable() raises:
    var killed = run_command(["sh", "-c", "kill -9 $$"], CommandOptions.tty())
    assert_equal(killed.exit_code, -1)
    assert_equal(killed.error, "signal: killed")
    var missing = run_command(["mogo-no-such-binary"], CommandOptions.plain())
    assert_equal(missing.exit_code, -1)
    assert_equal(
        missing.error,
        'exec: "mogo-no-such-binary": executable file not found in $PATH',
    )


def finish_with_background_descendant(options: CommandOptions) raises:
    var children = List[Child]()
    children.append(
        Child(["sh", "-c", "echo before; sleep 30 & exit 0"], options)
    )
    var polls = 0
    while poll_children(children, 100):
        polls += 1
        if polls >= 50:
            kill_group(children[0].pid, SIGKILL)
            raise Error(
                "child stayed active while a descendant held its output"
            )
    kill_group(children[0].pid, SIGKILL)  # Clean up the background sleep.
    var r = children[0].result()
    assert_true(r.succeeded())
    assert_equal(r.stdout, "before\n")


def test_exited_child_finishes_despite_background_descendant_tty() raises:
    finish_with_background_descendant(CommandOptions.tty())


def test_exited_child_finishes_despite_background_descendant_pipes() raises:
    finish_with_background_descendant(CommandOptions.plain())


def test_extra_environment_overrides() raises:
    var options = CommandOptions(False, ["MOGO_PROBE=one two", "HOME=/nowhere"])
    var r = run_command(["sh", "-c", 'echo "$MOGO_PROBE|$HOME"'], options)
    assert_equal(r.stdout, "one two|/nowhere\n")


def test_large_output_is_drained() raises:
    var r = run_command(
        ["sh", "-c", "yes x | head -c 300000"], CommandOptions.tty()
    )
    assert_equal(r.stdout.byte_length(), 300000)


def test_glob_match() raises:
    assert_true(
        glob_match("libclang_rt.asan*.so", "libclang_rt.asan-x86_64.so")
    )
    assert_true(glob_match("libclang_rt.asan*.so", "libclang_rt.asan.so"))
    assert_false(
        glob_match("libclang_rt.asan*.so", "libclang_rt.asan_static.a")
    )
    assert_true(glob_match("a?c", "abc"))


def fake_clang(dir: String, resource_dir: String) raises -> String:
    var path = dir + "/fake-clang"
    write_script(path, "#!/bin/sh\necho '" + resource_dir + "'\n")
    return path


def test_locate_asan_runtime_darwin_arm64() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir + "/res/lib/darwin")
    write_file(dir + "/res/lib/darwin/libclang_rt.asan_osx_dynamic.dylib", "")
    var runtime = locate_asan_runtime_with(
        "darwin/arm64", fake_clang(dir, dir + "/res")
    )
    var lib = dir + "/res/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"
    assert_equal(runtime.lib_path, lib)
    assert_equal(runtime.preload_var, "DYLD_INSERT_LIBRARIES")
    assert_equal(runtime.build_args, ["--external-libasan", lib])
    remove_all(dir)


def test_locate_asan_runtime_linux_amd64_picks_first_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir + "/res/lib/linux")
    write_file(dir + "/res/lib/linux/libclang_rt.asan-x86_64.so", "")
    write_file(dir + "/res/lib/linux/libclang_rt.asan-a.so", "")
    var runtime = locate_asan_runtime_with(
        "linux/amd64", fake_clang(dir, dir + "/res")
    )
    assert_equal(runtime.lib_path, dir + "/res/lib/linux/libclang_rt.asan-a.so")
    assert_equal(runtime.preload_var, "LD_PRELOAD")
    remove_all(dir)


def test_locate_asan_runtime_reports_resource_dir() raises:
    var dir = make_temp_dir("mogo-test-")
    var clang = fake_clang(dir, dir + "/res")
    try:
        _ = locate_asan_runtime_with("linux/amd64", clang)
    except e:
        var message = String(e)
        assert_true(
            "compatible AddressSanitizer runtime not found for linux/amd64"
            in message
        )
        assert_true(String("Compiler resource dir: ", dir, "/res") in message)
        assert_true("pixi add clang --platform linux-64" in message)
        remove_all(dir)
        return
    raise Error("expected lookup failure")


def test_locate_asan_runtime_rejects_unknown_platform() raises:
    try:
        _ = locate_asan_runtime_with("plan9/mips", "clang")
    except e:
        assert_equal(
            String(e),
            "AddressSanitizer runtime lookup is not configured for plan9/mips",
        )
        return
    raise Error("expected failure")


def test_markers_and_build_args() raises:
    var dir = make_temp_dir("mogo-test-")
    write_file(dir + "/plain.mojo", "def main():\n    pass\n")
    write_file(
        dir + "/skip.mojo", "# SKIP_DEBUG\n# SKIP_ASAN\ndef main():\n    pass\n"
    )
    assert_false(file_skips_asan(dir + "/plain.mojo"))
    assert_true(file_skips_asan(dir + "/skip.mojo"))
    assert_true(file_skips_debug(dir + "/skip.mojo"))
    assert_false(file_skips_debug(dir + "/missing.mojo"))
    var args: List[String] = ["-I", "src", "-g", "-D", "X=-g"]
    assert_equal(mojo_build_args_for_file(args, dir + "/plain.mojo"), args)
    assert_equal(
        mojo_build_args_for_file(args, dir + "/skip.mojo"),
        ["-I", "src", "-D", "X=-g"],
    )
    remove_all(dir)


def test_compile_command_with_asan_and_precompile() raises:
    var cfg = Config()
    cfg.mojo_build_args = ["-I", "src"]
    cfg.precompile_import_dir = "/art"
    cfg.asan_runtime.lib_path = "/lib/asan.so"
    cfg.asan_runtime.preload_var = "LD_PRELOAD"
    cfg.asan_runtime.build_args = ["--external-libasan", "/lib/asan.so"]
    assert_equal(
        compile_command(cfg, "t/a.mojo", "/art/a-123", True),
        [
            "mojo",
            "build",
            "-I",
            "src",
            "-I",
            "/art",
            "--sanitize",
            "address",
            "--external-libasan",
            "/lib/asan.so",
            "-o",
            "/art/a-123",
            "t/a.mojo",
        ],
    )
    var options = run_options(cfg, True)
    assert_true(options.fake_tty)
    assert_equal(options.env, ["LD_PRELOAD=/lib/asan.so"])
    assert_equal(len(run_options(cfg, False).env), 0)


def test_asan_report_marks_failure() raises:
    var r = ProcessResult(
        "==1==ERROR: AddressSanitizer: heap-use-after-free", "", True, 0, 0, ""
    )
    assert_true(asan_reported(r))
    var marked = mark_asan_failure(r^)
    assert_equal(marked.exit_code, 1)
    assert_equal(marked.error, "AddressSanitizer error detected")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
