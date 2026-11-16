from std.os import makedirs
from std.os.path import exists
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mogo_tester.libc import make_temp_dir
from mogo_tester.paths import (
    base_name,
    binary_path_for,
    clean_path,
    discover_tests,
    precompiled_package_path_for,
    remove_all,
    sanitize_binary_name,
)
from mogo_tester.sha256 import hex_encode, sha256


def touch(path: String) raises:
    with open(path, "w") as f:
        f.write("def main():\n    pass\n")


def discover_error(paths: List[String]) -> String:
    try:
        _ = discover_tests(paths)
    except e:
        return String(e)
    return ""


def test_sha256_known_vectors() raises:
    assert_equal(
        hex_encode(sha256(String("").as_bytes())),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )
    assert_equal(
        hex_encode(sha256(String("abc").as_bytes())),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    )
    assert_equal(
        hex_encode(
            sha256(
                String(
                    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
                ).as_bytes()
            )
        ),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    )


def test_clean_path() raises:
    assert_equal(clean_path("./test/"), "test")
    assert_equal(clean_path("a//b/../c/."), "a/c")
    assert_equal(clean_path("/../x"), "/x")
    assert_equal(clean_path("../x"), "../x")
    assert_equal(clean_path(""), ".")
    assert_equal(base_name("src/shared/"), "shared")
    assert_equal(base_name("/"), "/")


def test_discover_tests_top_level_only_sorted() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir + "/nested")
    touch(dir + "/b.mojo")
    touch(dir + "/a.mojo")
    touch(dir + "/notes.txt")
    touch(dir + "/nested/c.mojo")
    var paths = discover_tests([dir])
    assert_equal(paths, [dir + "/a.mojo", dir + "/b.mojo"])
    remove_all(dir)
    assert_false(exists(dir))


def test_discover_tests_operand_order_and_mixed() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir + "/suite")
    touch(dir + "/z.mojo")
    touch(dir + "/y.mojo")
    touch(dir + "/suite/m.mojo")
    var paths = discover_tests(
        [dir + "/z.mojo", dir + "/suite", dir + "/y.mojo"]
    )
    assert_equal(
        paths, [dir + "/z.mojo", dir + "/suite/m.mojo", dir + "/y.mojo"]
    )
    remove_all(dir)


def test_discover_tests_errors() raises:
    var dir = make_temp_dir("mogo-test-")
    makedirs(dir + "/empty")
    makedirs(dir + "/empty2")
    touch(dir + "/readme.md")
    assert_equal(
        discover_error([dir + "/readme.md"]),
        String("test file ", dir, "/readme.md must have .mojo extension"),
    )
    assert_equal(
        discover_error([dir + "/empty", dir + "/empty2"]),
        String(
            "no .mojo test files found in ", dir, "/empty, ", dir, "/empty2"
        ),
    )
    assert_true(
        "no such file or directory" in discover_error([dir + "/missing"])
    )
    remove_all(dir)


def test_binary_path_for_uses_hash_to_avoid_collisions() raises:
    var first = binary_path_for("/tmp/art", "a/test_x.mojo")
    var second = binary_path_for("/tmp/art", "b/test_x.mojo")
    assert_not_equal(first, second)
    assert_true(first.startswith("/tmp/art/test_x-"))
    assert_equal(
        first.byte_length(), String("/tmp/art/test_x-").byte_length() + 10
    )
    assert_true(
        binary_path_for("/tmp/art", "t/we ird$.mojo").startswith(
            "/tmp/art/we_ird_-"
        )
    )


def test_sanitize_binary_name() raises:
    assert_equal(sanitize_binary_name("ok-name_1.2"), "ok-name_1.2")
    assert_equal(sanitize_binary_name("ü b"), "__b")
    assert_equal(sanitize_binary_name(""), "test")


def test_precompiled_package_path_keeps_basename() raises:
    assert_equal(
        precompiled_package_path_for("/art", "src/shared/"), "/art/shared.mojoc"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
