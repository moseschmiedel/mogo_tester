"""AddressSanitizer runtime discovery and per-file opt-out markers."""

from std.os import getenv
from std.os.path import islink
from std.pathlib import Path

from .platform import Platform
from .process import CommandOptions, ProcessResult, run_command


@fieldwise_init
struct ASANRuntime(Copyable, Movable):
    """Build arguments and preload settings for ASAN-enabled test binaries."""

    var lib_path: Path
    var preload_var: String
    var build_args: List[String]

    def __init__(out self):
        self.lib_path = Path("")
        self.preload_var = ""
        self.build_args = List[String]()


def locate_asan_runtime() raises -> ASANRuntime:
    """Resolves the ASAN runtime for this platform using `CC`, or `clang`."""
    var clang = getenv("CC")
    if clang == "":
        clang = "clang"
    return locate_asan_runtime_with(Platform.current(), clang)


def locate_asan_runtime_with(
    platform: Platform, clang: String, out result: ASANRuntime
) raises:
    """Queries a clang resource directory and returns the build and preload
    settings needed to link and run ASAN-enabled Mojo binaries.

    Raises:
        Error: If ASAN lookup is not configured for platform, or no
            matching runtime library exists below the resource directory.
    """
    var pattern: String
    var preload_var: String
    var hint: String
    match platform:
        case .AARCH64_APPLE_MACOSX:
            pattern = "libclang_rt.asan_osx_dynamic.dylib"
            preload_var = "DYLD_INSERT_LIBRARIES"
            hint = "Install it with: pixi add clang --platform osx-arm64"
        case .X86_64_UNKNOWN_LINUX_GNU:
            pattern = "libclang_rt.asan*.so"
            preload_var = "LD_PRELOAD"
            hint = "Install it with: pixi add clang --platform linux-64"
        case _:
            raise Error(
                "AddressSanitizer runtime lookup is not configured for ",
                platform,
            )

    var resource_dir = Optional[Path]()
    var resolve_error = String("")
    try:
        resource_dir = resolve_clang_resource_dir(clang)
    except e:
        resolve_error = String(e)

    var lib_path = Optional[Path]()
    if resource_dir:
        try:
            lib_path = find_first_matching(
                resource_dir.value() / "lib", pattern
            )
        except e:
            raise Error("find AddressSanitizer runtime: ", e)

    if not lib_path:
        var message = String(
            "compatible AddressSanitizer runtime not found for ",
            platform,
            "\nCompiler queried: ",
            clang,
            " --print-resource-dir",
        )
        if resource_dir:
            message += String(
                "\nCompiler resource dir: ",
                resource_dir.value(),
                "\nSearched below: ",
                resource_dir.value() / "lib",
            )
        else:
            message += "\nCompiler resource dir: <unavailable>"
        message += "\n" + hint
        if resolve_error != "":
            message += "\nResolve error: " + resolve_error
        raise Error(message)

    var lib = lib_path.value()
    result = ASANRuntime()
    result.lib_path = lib
    result.preload_var = preload_var
    result.build_args = ["--external-libasan", String(lib)]


def resolve_clang_resource_dir(clang: String) raises -> Path:
    """Returns the directory reported by `clang --print-resource-dir`."""
    var result = run_command(
        [clang, "--print-resource-dir"], CommandOptions.plain()
    )
    if not result.succeeded():
        raise Error(result.error)
    var resource_dir = String(result.stdout.strip())
    if resource_dir == "":
        raise Error("empty compiler resource directory")
    return Path(resource_dir)


def find_first_matching(root: Path, pattern: String) raises -> Optional[Path]:
    """Walks root and returns the lexicographically first file path whose
    name matches the glob pattern, or None when nothing matches."""
    if not root.exists():
        return None
    var matches = List[Path]()
    _walk(root, pattern, matches)
    if len(matches) == 0:
        return None
    sort(Span(matches))
    return matches[0]


def _walk(dir: Path, pattern: String, mut matches: List[Path]) raises:
    for entry in dir.listdir():
        var path = dir / entry.path
        if path.is_dir() and not islink(path):
            _walk(path, pattern, matches)
        elif glob_match(pattern, entry.path):
            matches.append(path)


def glob_match(pattern: String, name: String) -> Bool:
    """Matches name against a glob supporting `*` and `?`."""
    var p = pattern.as_bytes()
    var n = name.as_bytes()
    var pi = 0
    var ni = 0
    var star = -1
    var mark = 0
    while ni < len(n):
        if pi < len(p) and (p[pi] == UInt8(ord("?")) or p[pi] == n[ni]):
            pi += 1
            ni += 1
        elif pi < len(p) and p[pi] == UInt8(ord("*")):
            star = pi
            mark = ni
            pi += 1
        elif star >= 0:
            pi = star + 1
            mark += 1
            ni = mark
        else:
            return False
    while pi < len(p) and p[pi] == UInt8(ord("*")):
        pi += 1
    return pi == len(p)


def asan_reported(result: ProcessResult) -> Bool:
    """Detects ASAN reports in output, even when the exit status is zero."""
    var output = result.stdout + result.stderr
    return "ERROR:" in output and "AddressSanitizer" in output


def mark_asan_failure(mut result: ProcessResult):
    """Turns result into a failure after an ASAN report."""
    if result.exit_code == 0:
        result.exit_code = 1
    if result.error == "":
        result.error = "AddressSanitizer error detected"
