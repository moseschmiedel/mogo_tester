"""Artifact names for compiled test binaries and precompiled packages."""

from std.pathlib import Path

from ..fs.paths import package_name
from ..fs.sha256 import hex_encode, sha256


def sanitize_binary_name(name: String, out result: String):
    """Replaces characters outside `[A-Za-z0-9._-]` with underscores."""
    result = String("")
    for cp in name.codepoints():
        var c = Int(cp)
        if (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("-")
            or c == ord("_")
            or c == ord(".")
        ):
            result += String(cp)
        else:
            result += "_"
    if result == "":
        result = "test"


def binary_path_for(artifact_dir: Path, path: Path) -> Path:
    """Derives a filesystem-safe artifact path for a source file. A hash of
    the full path keeps identical file names from colliding."""
    var name = path.name()
    var stem = String(
        name[byte = 0 : name.byte_length() - path.suffix().byte_length()]
    )
    var digest = hex_encode(sha256(String(path).as_bytes()))
    return artifact_dir / (
        sanitize_binary_name(stem) + "-" + String(digest[byte=0:10])
    )


def precompiled_package_path_for(artifact_dir: Path, path: Path) -> Path:
    """Returns the .mojoc path whose file name becomes the importable package
    name."""
    return artifact_dir / (package_name(path) + ".mojoc")
