"""Tests for test discovery, source markers, and artifact names."""

from std.os import makedirs
from std.pathlib import Path
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mogo_tester.fs.paths import make_temp_dir, remove_all
from mogo_tester.suite.artifacts import (
    binary_path_for,
    precompiled_package_path_for,
    sanitize_binary_name,
)
from mogo_tester.suite.discovery import discover_tests
from mogo_tester.suite.markers import SourceMarkers, read_markers


def touch(path: Path) raises:
    path.write_text("def main():\n    pass\n")


def discover_error(paths: List[Path]) -> String:
    try:
        _ = discover_tests(paths)
    except e:
        return String(e)
    return ""


def test_discover_tests_top_level_only_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "nested")
    touch(dir / "b.mojo")
    touch(dir / "a.mojo")
    touch(dir / "notes.txt")
    touch(dir / "nested" / "c.mojo")
    assert_equal(discover_tests([dir]), [dir / "a.mojo", dir / "b.mojo"])
    remove_all(dir)
    assert_false(dir.exists())


def test_discover_tests_cleans_directory_operands() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "suite")
    touch(dir / "suite" / "m.mojo")
    assert_equal(
        discover_tests([Path(String(dir, "/./suite/"))]),
        [dir / "suite" / "m.mojo"],
    )
    remove_all(dir)


def test_discover_tests_operand_order_and_mixed() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "suite")
    touch(dir / "z.mojo")
    touch(dir / "y.mojo")
    touch(dir / "suite" / "m.mojo")
    assert_equal(
        discover_tests([dir / "z.mojo", dir / "suite", dir / "y.mojo"]),
        [dir / "z.mojo", dir / "suite" / "m.mojo", dir / "y.mojo"],
    )
    remove_all(dir)


def test_discover_tests_errors() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "empty")
    makedirs(dir / "empty2")
    touch(dir / "readme.md")
    assert_equal(
        discover_error([dir / "readme.md"]),
        String("test file ", dir, "/readme.md must have .mojo extension"),
    )
    assert_equal(
        discover_error([dir / "empty", dir / "empty2"]),
        String(
            "no .mojo test files found in ", dir, "/empty, ", dir, "/empty2"
        ),
    )
    assert_true(
        "no such file or directory" in discover_error([dir / "missing"])
    )
    remove_all(dir)


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


def test_binary_path_for_uses_hash_to_avoid_collisions() raises:
    var first = binary_path_for("/tmp/art", "a/test_x.mojo")
    var second = binary_path_for("/tmp/art", "b/test_x.mojo")
    assert_not_equal(first, second)
    assert_true(first.path.startswith("/tmp/art/test_x-"))
    assert_equal(
        first.path.byte_length(),
        String("/tmp/art/test_x-").byte_length() + 10,
    )
    assert_true(
        binary_path_for("/tmp/art", "t/we ird$.mojo").path.startswith(
            "/tmp/art/we_ird_-"
        )
    )


def test_sanitize_binary_name() raises:
    assert_equal(sanitize_binary_name("ok-name_1.2"), "ok-name_1.2")
    assert_equal(sanitize_binary_name("ü b"), "__b")
    assert_equal(sanitize_binary_name(""), "test")


def test_precompiled_package_path_keeps_package_name() raises:
    assert_equal(
        precompiled_package_path_for("/art", "src/shared/"),
        Path("/art/shared.mojoc"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
