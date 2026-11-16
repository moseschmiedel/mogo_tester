from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.cli.args import Config, UsageError, parse_args, usage


def parse_error(args: List[String]) -> String:
    try:
        _ = parse_args(args)
    except e:
        return e.message
    return ""


def test_requires_test_path() raises:
    assert_equal(parse_error([]), "usage: mogo-tester [options] <test-path>...")


def test_rejects_invalid_parallel() raises:
    assert_equal(
        parse_error(["--parallel", "0", "test"]), "parallel must be >= 1"
    )
    assert_equal(
        parse_error(["--parallel", "x", "test"]),
        'invalid value "x" for flag -parallel: parse error',
    )


def test_rejects_unknown_flag() raises:
    try:
        _ = parse_args(["--nope", "test"])
    except e:
        assert_equal(e.message, "flag provided but not defined: -nope")
        assert_true(e.show_usage)
        return
    raise Error("expected a usage error")


def test_preserves_repeated_mojo_build_args() raises:
    var cfg = parse_args(
        [
            "--mojo-build-arg",
            "-I",
            "--mojo-build-arg",
            "path with spaces",
            "--mojo-build-arg=-g",
            "test",
        ]
    )
    assert_equal(cfg.mojo_build_args, ["-I", "path with spaces", "-g"])
    assert_equal(cfg.test_paths, ["test"])


def test_splits_mojo_build_args_after_repeated_args() raises:
    var cfg = parse_args(
        [
            "--mojo-build-args",
            "  -I src   -g ",
            "--mojo-build-arg",
            "-D",
            "test",
        ]
    )
    assert_equal(cfg.mojo_build_args, ["-D", "-I", "src", "-g"])


def test_allows_options_after_test_paths() raises:
    var cfg = parse_args(
        [
            "test",
            "--parallel",
            "3",
            "smoke/a.mojo",
            "--no-color",
            "-keep-artifacts",
        ]
    )
    assert_equal(cfg.test_paths, ["test", "smoke/a.mojo"])
    assert_equal(cfg.parallel, 3)
    assert_true(cfg.no_color)
    assert_true(cfg.keep_artifacts)


def test_honors_end_of_options() raises:
    var cfg = parse_args(["--asan", "--", "--weird.mojo", "-"])
    assert_true(cfg.asan)
    assert_equal(cfg.test_paths, ["--weird.mojo", "-"])


def test_bool_flags_accept_inline_values() raises:
    var cfg = parse_args(["--no-color=false", "--asan=true", "t"])
    assert_false(cfg.no_color)
    assert_true(cfg.asan)


def test_value_option_needs_argument() raises:
    assert_equal(
        parse_error(["t", "--precompile"]),
        "flag needs an argument: -precompile",
    )


def test_version_and_help_need_no_paths() raises:
    assert_true(parse_args(["--version"]).show_version)
    assert_true(parse_args(["-h"]).show_help)
    assert_true(parse_args(["t", "--help"]).show_help)


def test_usage_mentions_default_parallel() raises:
    assert_true("(default: 7)" in usage(7))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
