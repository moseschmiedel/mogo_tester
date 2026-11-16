"""Tests for the filesystem and hashing helpers."""

from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mogo_tester.fs.paths import clean, make_temp_dir, package_name, remove_all
from mogo_tester.fs.sha256 import hex_encode, sha256


def touch(path: Path) raises:
    path.write_text("def main():\n    pass\n")


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


def test_clean() raises:
    assert_equal(clean("./test/"), Path("test"))
    assert_equal(clean("a//b/../c/."), Path("a/c"))
    assert_equal(clean("/../x"), Path("/x"))
    assert_equal(clean("../x"), Path("../x"))
    assert_equal(clean(""), Path("."))
    assert_equal(package_name("src/shared/"), "shared")


def test_make_temp_dir_and_remove_all() raises:
    var dir = make_temp_dir("mogo-test-")
    assert_true(dir.is_dir())
    assert_true(dir.name().startswith("mogo-test-"))
    makedirs(dir / "a" / "b")
    touch(dir / "a" / "b" / "f.mojo")
    remove_all(dir)
    assert_false(dir.exists())
    remove_all(dir)  # Removing a missing path is not an error.


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
