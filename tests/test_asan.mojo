"""Tests for ASAN runtime lookup, platforms, source markers, and the
compile command built from them."""

from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.args import Config
from mogo_tester.asan import (
    asan_reported,
    glob_match,
    locate_asan_runtime_with,
    mark_asan_failure,
)
from mogo_tester.markers import SourceMarkers, read_markers
from mogo_tester.paths import make_temp_dir, remove_all
from mogo_tester.platform import Platform
from mogo_tester.process import CommandOptions, ProcessResult, run_command
from mogo_tester.runner import (
    compile_command,
    mojo_build_args_for_file,
    run_options,
)


def write_script(path: Path, content: String) raises:
    path.write_text(content)
    _ = run_command(["chmod", "+x", String(path)], CommandOptions.plain())


def fake_clang(dir: Path, resource_dir: Path) raises -> String:
    var path = dir / "fake-clang"
    write_script(path, String("#!/bin/sh\necho '", resource_dir, "'\n"))
    return String(path)


# ===-----------------------------------------------------------------------===#
# Platform
# ===-----------------------------------------------------------------------===#


def test_platform_uses_target_triples() raises:
    assert_equal(String(Platform.AARCH64_APPLE_MACOSX), "aarch64-apple-macosx")
    assert_equal(String(Platform.X86_64_APPLE_MACOSX), "x86_64-apple-macosx")
    assert_equal(
        String(Platform.X86_64_UNKNOWN_LINUX_GNU), "x86_64-unknown-linux-gnu"
    )
    assert_equal(
        String(Platform.AARCH64_UNKNOWN_LINUX_GNU), "aarch64-unknown-linux-gnu"
    )
    assert_true(Platform.current() == Platform.current())
    assert_false(Platform.AARCH64_APPLE_MACOSX == Platform.X86_64_APPLE_MACOSX)


# ===-----------------------------------------------------------------------===#
# ASAN runtime lookup
# ===-----------------------------------------------------------------------===#


def test_glob_match() raises:
    assert_true(
        glob_match("libclang_rt.asan*.so", "libclang_rt.asan-x86_64.so")
    )
    assert_true(glob_match("libclang_rt.asan*.so", "libclang_rt.asan.so"))
    assert_false(
        glob_match("libclang_rt.asan*.so", "libclang_rt.asan_static.a")
    )
    assert_true(glob_match("a?c", "abc"))


def test_locate_asan_runtime_macos_arm64() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "res" / "lib" / "darwin")
    var lib = (
        dir / "res" / "lib" / "darwin" / "libclang_rt.asan_osx_dynamic.dylib"
    )
    lib.write_text("")
    var runtime = locate_asan_runtime_with(
        Platform.AARCH64_APPLE_MACOSX, fake_clang(dir, dir / "res")
    )
    assert_equal(runtime.lib_path, lib)
    assert_equal(runtime.preload_var, "DYLD_INSERT_LIBRARIES")
    assert_equal(runtime.build_args, ["--external-libasan", String(lib)])
    remove_all(dir)


def test_locate_asan_runtime_linux_x86_64_picks_first_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    var lib_dir = dir / "res" / "lib" / "linux"
    makedirs(lib_dir)
    (lib_dir / "libclang_rt.asan-x86_64.so").write_text("")
    (lib_dir / "libclang_rt.asan-a.so").write_text("")
    var runtime = locate_asan_runtime_with(
        Platform.X86_64_UNKNOWN_LINUX_GNU, fake_clang(dir, dir / "res")
    )
    assert_equal(runtime.lib_path, lib_dir / "libclang_rt.asan-a.so")
    assert_equal(runtime.preload_var, "LD_PRELOAD")
    remove_all(dir)


def test_locate_asan_runtime_reports_resource_dir() raises:
    var dir = make_temp_dir("mogo-test-")
    var clang = fake_clang(dir, dir / "res")
    try:
        _ = locate_asan_runtime_with(Platform.X86_64_UNKNOWN_LINUX_GNU, clang)
    except e:
        var message = String(e)
        assert_true(
            "compatible AddressSanitizer runtime not found for"
            " x86_64-unknown-linux-gnu"
            in message
        )
        assert_true(String("Compiler resource dir: ", dir, "/res") in message)
        assert_true("pixi add clang --platform linux-64" in message)
        remove_all(dir)
        return
    raise Error("expected lookup failure")


def test_locate_asan_runtime_rejects_unconfigured_platform() raises:
    try:
        _ = locate_asan_runtime_with(
            Platform.AARCH64_UNKNOWN_LINUX_GNU, "clang"
        )
    except e:
        assert_equal(
            String(e),
            (
                "AddressSanitizer runtime lookup is not configured for"
                " aarch64-unknown-linux-gnu"
            ),
        )
        return
    raise Error("expected failure")


def test_asan_report_marks_failure() raises:
    var r = ProcessResult(
        "==1==ERROR: AddressSanitizer: heap-use-after-free", "", True, 0, 0, ""
    )
    assert_true(asan_reported(r))
    mark_asan_failure(r)
    assert_equal(r.exit_code, 1)
    assert_equal(r.error, "AddressSanitizer error detected")


# ===-----------------------------------------------------------------------===#
# Source markers
# ===-----------------------------------------------------------------------===#


def markers_for(content: String) raises -> SourceMarkers:
    var dir = make_temp_dir("mogo-test-")
    var path = dir / "t.mojo"
    path.write_text(content)
    var markers = read_markers(path)
    remove_all(dir)
    return markers^


def test_markers_in_comment_header() raises:
    var both = markers_for("# SKIP_DEBUG\n# SKIP_ASAN\ndef main():\n    pass\n")
    assert_true(both.skip_debug)
    assert_true(both.skip_asan)
    var spaced = markers_for(
        "#!shebang\n\n  # SKIP_ASAN reason\ndef main(): pass"
    )
    assert_true(spaced.skip_asan)
    assert_false(spaced.skip_debug)


def test_markers_after_header_are_ignored() raises:
    var late = markers_for("def main():\n    pass\n# SKIP_ASAN\n")
    assert_false(late.skip_asan)


def test_marker_header_longer_than_one_chunk() raises:
    var header = String("")
    for _ in range(100):
        header += "# license line padding padding padding\n"
    var markers = markers_for(header + "# SKIP_DEBUG\ndef main(): pass\n")
    assert_true(markers.skip_debug)


def test_markers_for_unreadable_file() raises:
    var markers = read_markers(Path("/nonexistent/t.mojo"))
    assert_false(markers.skip_asan)
    assert_false(markers.skip_debug)


# ===-----------------------------------------------------------------------===#
# Build arguments
# ===-----------------------------------------------------------------------===#


def test_skip_debug_drops_only_exact_g() raises:
    var args: List[String] = ["-I", "src", "-g", "-D", "X=-g"]
    assert_equal(mojo_build_args_for_file(args, SourceMarkers()), args)
    assert_equal(
        mojo_build_args_for_file(args, SourceMarkers(False, True)),
        ["-I", "src", "-D", "X=-g"],
    )


def test_compile_command_with_asan_and_precompile() raises:
    var cfg = Config()
    cfg.mojo_build_args = ["-I", "src"]
    cfg.precompile_import_dir = Path("/art")
    cfg.asan_runtime.lib_path = Path("/lib/asan.so")
    cfg.asan_runtime.preload_var = "LD_PRELOAD"
    cfg.asan_runtime.build_args = ["--external-libasan", "/lib/asan.so"]
    assert_equal(
        compile_command(
            cfg, Path("t/a.mojo"), Path("/art/a-123"), SourceMarkers(), True
        ),
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
    assert_equal(options.env.entries(), ["LD_PRELOAD=/lib/asan.so"])
    assert_equal(len(run_options(cfg, False).env), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
