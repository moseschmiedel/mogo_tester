"""Tests for test discovery, source markers, artifact names, and doctests."""

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
from mogo_tester.suite.discovery import discover_tests, empty_dir_warning
from mogo_tester.suite.doctest import (
    discover_doctest_files,
    parse_fence_info,
    remap_locations,
    scan_doctests,
)
from mogo_tester.suite.exclude import (
    apply_excludes,
    exclude_matches,
    glob_match,
)
from mogo_tester.suite.markers import SourceMarkers, read_markers


def touch(path: Path) raises:
    path.write_text("def main():\n    pass\n")


def discover_error(paths: List[Path], recursive: Bool = False) -> String:
    try:
        _ = discover_tests(paths, recursive)
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
    assert_equal(discover_tests([dir]).paths, [dir / "a.mojo", dir / "b.mojo"])
    remove_all(dir)
    assert_false(dir.exists())


def test_discover_tests_cleans_directory_operands() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "suite")
    touch(dir / "suite" / "m.mojo")
    assert_equal(
        discover_tests([Path(String(dir, "/./suite/"))]).paths,
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
        discover_tests([dir / "z.mojo", dir / "suite", dir / "y.mojo"]).paths,
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
            "no .mojo test files found in ",
            dir,
            "/empty, ",
            dir,
            "/empty2 (use --recursive to search subdirectories)",
        ),
    )
    assert_true(
        "no such file or directory" in discover_error([dir / "missing"])
    )
    assert_equal(
        discover_error([dir / "empty"], recursive=True),
        String("no .mojo test files found in ", dir, "/empty"),
    )
    remove_all(dir)


def test_discover_tests_recursive_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "b" / "deep")
    makedirs(dir / "a")
    touch(dir / "z.mojo")
    touch(dir / "b" / "deep" / "x.mojo")
    touch(dir / "b" / "notes.txt")
    touch(dir / "a" / "y.mojo")
    assert_equal(
        discover_tests([dir], recursive=True).paths,
        [dir / "a" / "y.mojo", dir / "b" / "deep" / "x.mojo", dir / "z.mojo"],
    )
    remove_all(dir)


def test_discover_tests_reports_empty_dirs() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "nested" / "sub")
    makedirs(dir / "suite")
    touch(dir / "nested" / "sub" / "a.mojo")
    touch(dir / "suite" / "b.mojo")
    var found = discover_tests([dir / "nested", dir / "suite"])
    assert_equal(found.paths, [dir / "suite" / "b.mojo"])
    assert_equal(found.empty_dirs, [dir / "nested"])
    assert_equal(
        len(discover_tests([dir / "nested"], recursive=True).empty_dirs), 0
    )
    assert_equal(
        empty_dir_warning(Path("docs/test"), False),
        (
            "no .mojo files found in docs/test (use --recursive to search"
            " subdirectories)"
        ),
    )
    assert_equal(
        empty_dir_warning(Path("docs/test"), True),
        "no .mojo files found in docs/test",
    )
    remove_all(dir)


def test_glob_match_elements() raises:
    assert_true(glob_match("a.mojo", "a.mojo"))
    assert_false(glob_match("a.mojo", "b.mojo"))
    assert_true(glob_match("*_test.mojo", "x_test.mojo"))
    assert_true(glob_match("*_test.mojo", "_test.mojo"))
    assert_false(glob_match("*.mojo", "d/a.mojo"))
    assert_true(glob_match("a?c", "abc"))
    assert_false(glob_match("a?c", "ac"))
    assert_true(glob_match("[ab]*", "bx"))
    assert_false(glob_match("[!ab]*", "bx"))
    assert_true(glob_match("x[0-9]", "x7"))
    assert_false(glob_match("x[0-9]", "xa"))
    assert_true(glob_match("x[", "x["))
    assert_true(glob_match("\\*", "*"))
    assert_false(glob_match("\\*", "a"))
    assert_true(glob_match("a*b*c", "aXbYbZc"))


def test_glob_match_unicode_characters() raises:
    assert_true(glob_match("?.mojo", "é.mojo"))
    assert_true(glob_match("[é].mojo", "é.mojo"))
    assert_true(glob_match("[à-ê].mojo", "é.mojo"))
    assert_false(glob_match("[!é].mojo", "é.mojo"))
    assert_true(glob_match("t_?ü.mojo", "t_xü.mojo"))
    assert_false(glob_match("??.mojo", "é.mojo"))
    assert_true(exclude_matches("?.mojo", Path("docs/é.mojo")))


def test_glob_match_double_star() raises:
    assert_true(glob_match("**/a.mojo", "a.mojo"))
    assert_true(glob_match("**/a.mojo", "x/y/a.mojo"))
    assert_true(glob_match("docs/**/a.mojo", "docs/a.mojo"))
    assert_true(glob_match("docs/**/a.mojo", "docs/t/g/a.mojo"))
    assert_false(glob_match("docs/**/a.mojo", "src/t/a.mojo"))
    assert_true(glob_match("docs/**", "docs/t/a.mojo"))
    assert_true(glob_match("**/**/h_*.mojo", "/abs/h_x.mojo"))
    assert_false(glob_match("docs/*", "docs/t/a.mojo"))


def test_exclude_matches_path_or_basename() raises:
    assert_true(exclude_matches("a_test.mojo", Path("docs/t/a_test.mojo")))
    assert_true(exclude_matches("docs/t/*.mojo", Path("./docs//t/a.mojo")))
    assert_true(exclude_matches("./docs/t/a.mojo", Path("docs/t/a.mojo")))
    assert_false(exclude_matches("t/a.mojo", Path("docs/t/a.mojo")))


def test_apply_excludes() raises:
    var paths: List[Path] = [
        Path("t/a.mojo"),
        Path("t/b.mojo"),
        Path("t/c.mojo"),
    ]
    var result = apply_excludes(paths, ["b.mojo", "t/[ab].mojo", "zz.mojo"])
    assert_equal(result.kept, [Path("t/c.mojo")])
    assert_equal(result.skipped, [Path("t/a.mojo"), Path("t/b.mojo")])
    assert_equal(result.unmatched, ["zz.mojo"])
    var none = apply_excludes(paths, [])
    assert_equal(len(none.kept), 3)
    assert_equal(len(none.skipped), 0)


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


def test_build_args_from_comment_header() raises:
    """Accumulate whitespace-separated flags in comment-header order."""
    var markers = markers_for(
        "# license\n  # MOJO_BUILD_ARGS: -D\tASSERT=all\n"
        "# MOJO_BUILD_ARGS: --debug-level line-tables\n"
        "def main(): pass\n# MOJO_BUILD_ARGS: -g0\n"
    )
    assert_equal(
        markers.build_args, ["-D", "ASSERT=all", "--debug-level", "line-tables"]
    )


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


def test_discover_doctest_files_recursive_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir / "guide")
    makedirs(dir / ".pixi")
    touch(dir / "guide" / "b.md")
    touch(dir / "a.mojo")
    touch(dir / "notes.txt")
    touch(dir / ".pixi" / "hidden.md")
    touch(dir / "readme.txt")
    var found = discover_doctest_files([dir, dir / "readme.txt"])
    assert_equal(len(found), 3)
    assert_equal(found[0], dir / "a.mojo")
    assert_equal(found[1], dir / "guide" / "b.md")
    assert_equal(found[2], dir / "readme.txt")
    var message = String()
    try:
        _ = discover_doctest_files([dir / "missing"])
    except e:
        message = String(e)
    assert_true("no such file or directory" in message)
    remove_all(dir)


def test_parse_fence_info_attributes() raises:
    var info = parse_fence_info(' {doctest="intro" global=true hide=true}')
    assert_true(Bool(info))
    assert_equal(info.value().name, "intro")
    assert_true(info.value().is_global)

    var unquoted = parse_fence_info(" {doctest=intro}")
    assert_equal(unquoted.value().name, "intro")
    assert_false(unquoted.value().is_global)


def test_parse_fence_info_without_doctest() raises:
    assert_false(Bool(parse_fence_info("")))
    assert_false(Bool(parse_fence_info(" {hide=true}")))


def test_markdown_wraps_body_in_main() raises:
    var text = String(
        "Intro\n"
        '```mojo {doctest="a" global=true}\n'
        "from std.testing import assert_equal\n"
        "```\n"
        "Text\n"
        '```mojo {doctest="a"}\n'
        "var x = 1\n"
        "\n"
        "assert_equal(x, 1)\n"
        "```\n"
    )
    var tests = scan_doctests("guide.md", text)
    assert_equal(len(tests), 1)
    assert_equal(tests[0].error, "")
    assert_equal(tests[0].label(), "guide.md:2#a")
    assert_equal(
        tests[0].code,
        (
            "from std.testing import assert_equal\n"
            "def main() raises:\n"
            "    var x = 1\n"
            "\n"
            "    assert_equal(x, 1)\n"
        ),
    )
    assert_equal(tests[0].line_map, [3, 0, 7, 8, 9])


def test_global_main_continuation_is_kept() raises:
    var text = String(
        '```mojo {doctest="g" global=true hide=true}\n'
        "def main() raises:\n"
        "    var x = 1\n"
        "```\n"
        '```mojo {doctest="g" global=true}\n'
        "    print(x)\n"
        "```\n"
    )
    var tests = scan_doctests("guide.md", text)
    assert_equal(
        tests[0].code, "def main() raises:\n    var x = 1\n    print(x)\n"
    )


def test_global_only_doctest_gets_empty_main() raises:
    var text = String(
        '```mojo {doctest="decl" global=true}\nstruct A:\n    pass\n```\n'
    )
    var tests = scan_doctests("a.md", text)
    assert_equal(
        tests[0].code, "struct A:\n    pass\ndef main() raises:\n    pass\n"
    )


def test_main_conflict_is_reported() raises:
    var text = String(
        '```mojo {doctest="r" global=true}\ndef main() raises:\n    pass\n```\n'
        '```mojo {doctest="r"}\nmain()\n```\n'
    )
    var tests = scan_doctests("README.md", text)
    assert_true(tests[0].error.find("def main") >= 0)
    assert_equal(tests[0].code, "")


def test_docstrings_scope_names_and_strip_indent() raises:
    var text = String(
        "struct A:\n"
        '    """Doc.\n'
        "\n"
        '    ```mojo {doctest="ex"}\n'
        "    if True:\n"
        "        print(1)\n"
        "    ```\n"
        '    """\n'
        "\n"
        "    def f(self):\n"
        '        """Doc.\n'
        "\n"
        '        ```mojo {doctest="ex"}\n'
        "        print(2)\n"
        "        ```\n"
        '        """\n'
        "        pass\n"
    )
    var tests = scan_doctests("src/a.mojo", text)
    assert_equal(len(tests), 2)
    assert_equal(
        tests[0].code, "def main() raises:\n    if True:\n        print(1)\n"
    )
    assert_equal(tests[1].code, "def main() raises:\n    print(2)\n")
    assert_equal(tests[1].line, 13)


def test_other_fences_are_ignored() raises:
    var text = String(
        '```mojo\nnot a doctest\n```\n```sh\n```mojo {doctest="x"}\n```\n'
    )
    assert_equal(len(scan_doctests("a.md", text)), 0)


def test_tilde_fences_hide_nested_blocks() raises:
    var text = String(
        "~~~markdown\n"
        '```mojo {doctest="example"}\n'
        "print(1)\n"
        "```\n"
        "~~~\n"
        '~~~mojo {doctest="tilde"}\n'
        "print(2)\n"
        "```\n"
        "~~~\n"
    )
    var tests = scan_doctests("a.md", text)
    assert_equal(len(tests), 1)
    assert_equal(tests[0].name, "tilde")
    assert_equal(tests[0].code, "def main() raises:\n    print(2)\n    ```\n")


def test_single_quoted_docstrings_scope_names() raises:
    var text = String(
        "def f():\n"
        "    '''Doc with \"\"\" inside.\n"
        '    ```mojo {doctest="ex"}\n'
        "    print(1)\n"
        "    ```\n"
        "    '''\n"
        "    pass\n"
        "def g():\n"
        "    '''Doc.\n"
        '    ```mojo {doctest="ex"}\n'
        "    print(2)\n"
        "    ```\n"
        "    '''\n"
        "    pass\n"
    )
    var tests = scan_doctests("a.mojo", text)
    assert_equal(len(tests), 2)
    assert_equal(tests[0].code, "def main() raises:\n    print(1)\n")
    assert_equal(tests[1].code, "def main() raises:\n    print(2)\n")


def test_longer_fences_hide_nested_blocks() raises:
    var text = String(
        "````markdown\n"
        '```mojo {doctest="inner"}\n'
        "print(1)\n"
        "```\n"
        "````\n"
        '````mojo {doctest="outer"}\n'
        "print(2)\n"
        "```\n"
        "````\n"
    )
    var tests = scan_doctests("a.md", text)
    assert_equal(len(tests), 1)
    assert_equal(tests[0].name, "outer")
    assert_equal(tests[0].code, "def main() raises:\n    print(2)\n    ```\n")


def test_unterminated_and_malformed_fences() raises:
    var tests = scan_doctests("a.md", '```mojo {doctest="u"}\nprint(1)\n')
    assert_equal(tests[0].error, "line 1: unterminated code fence")

    var bad = scan_doctests("a.md", "```mojo doctest=x\n```\n")
    assert_true(bad[0].error.startswith("line 1: expected `{...}`"))


def test_remap_locations() raises:
    var text = String('```mojo {doctest="a"}\nprint(undefined)\n```\n')
    var test = scan_doctests("docs/a.md", text)[0].copy()
    var output = String(
        "/tmp/x/a.mojo:2:11: error: use of unknown declaration\n"
        "/tmp/x/a.mojo:1:1: note: here\n"
    )
    assert_equal(
        remap_locations(output, "/tmp/x/a.mojo", test),
        (
            "docs/a.md:2:11: error: use of unknown declaration\n"
            "/tmp/x/a.mojo:1:1: note: here\n"
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
