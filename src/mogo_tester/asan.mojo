"""AddressSanitizer runtime discovery and per-file opt-out markers."""

from std.os import getenv, listdir
from std.os.path import isdir, islink, join, exists
from std.sys import CompilationTarget

from .process import CommandOptions, ProcessResult, run_command


@fieldwise_init
struct ASANRuntime(Copyable, Movable):
    """Build arguments and preload settings for ASAN-enabled test binaries."""

    var lib_path: String
    var preload_var: String
    var build_args: List[String]

    def __init__(out self):
        self.lib_path = ""
        self.preload_var = ""
        self.build_args = List[String]()


def current_platform() -> String:
    """Returns the platform as `GOOS/GOARCH`-style text, e.g. darwin/arm64."""
    comptime if CompilationTarget.is_macos():
        comptime if CompilationTarget.is_arm():
            return "darwin/arm64"
        else:
            return "darwin/amd64"
    else:
        comptime if CompilationTarget.is_x86():
            return "linux/amd64"
        else:
            return "linux/arm64"


def locate_asan_runtime() raises -> ASANRuntime:
    """Resolves the ASAN runtime for this platform using `CC`, or `clang`."""
    var clang = getenv("CC")
    if clang == "":
        clang = "clang"
    return locate_asan_runtime_with(current_platform(), clang)


def locate_asan_runtime_with(
    platform: String, clang: String
) raises -> ASANRuntime:
    """Queries a clang resource directory and returns the build and preload
    settings needed to link and run ASAN-enabled Mojo binaries."""
    var pattern: String
    var preload_var: String
    var hint: String
    if platform == "darwin/arm64":
        pattern = "libclang_rt.asan_osx_dynamic.dylib"
        preload_var = "DYLD_INSERT_LIBRARIES"
        hint = "Install it with: pixi add clang --platform osx-arm64"
    elif platform == "linux/amd64":
        pattern = "libclang_rt.asan*.so"
        preload_var = "LD_PRELOAD"
        hint = "Install it with: pixi add clang --platform linux-64"
    else:
        raise Error(
            "AddressSanitizer runtime lookup is not configured for ", platform
        )

    var resource_dir = String("")
    var resolve_error = String("")
    try:
        resource_dir = resolve_clang_resource_dir(clang)
    except e:
        resolve_error = String(e)

    var lib_path = String("")
    if resolve_error == "":
        try:
            lib_path = find_first_matching(join(resource_dir, "lib"), pattern)
        except e:
            raise Error("find AddressSanitizer runtime: ", e)

    if lib_path == "":
        var message = String(
            "compatible AddressSanitizer runtime not found for ",
            platform,
            "\nCompiler queried: ",
            clang,
            " --print-resource-dir",
        )
        if resource_dir != "":
            message += String(
                "\nCompiler resource dir: ",
                resource_dir,
                "\nSearched below: ",
                join(resource_dir, "lib"),
            )
        else:
            message += "\nCompiler resource dir: <unavailable>"
        message += "\n" + hint
        if resolve_error != "":
            message += "\nResolve error: " + resolve_error
        raise Error(message)

    var runtime = ASANRuntime()
    runtime.lib_path = lib_path
    runtime.preload_var = preload_var
    runtime.build_args = ["--external-libasan", lib_path]
    return runtime^


def resolve_clang_resource_dir(clang: String) raises -> String:
    """Returns the directory reported by `clang --print-resource-dir`."""
    var result = run_command(
        [clang, "--print-resource-dir"], CommandOptions.plain()
    )
    if not result.succeeded():
        raise Error(result.error)
    var resource_dir = String(result.stdout.strip())
    if resource_dir == "":
        raise Error("empty compiler resource directory")
    return resource_dir^


def find_first_matching(root: String, pattern: String) raises -> String:
    """Walks root and returns the lexicographically first file path whose
    basename matches the glob pattern, or "" when nothing matches."""
    if not exists(root):
        return ""
    var matches = List[String]()
    _walk(root, pattern, matches)
    if len(matches) == 0:
        return ""
    sort(Span(matches))
    return matches[0]


def _walk(dir: String, pattern: String, mut matches: List[String]) raises:
    var names = listdir(dir)
    sort(Span(names))
    for name in names:
        var path = join(dir, name)
        if isdir(path) and not islink(path):
            _walk(path, pattern, matches)
        elif glob_match(pattern, name):
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


def file_contains(path: String, marker: String) -> Bool:
    """Reports whether the file at path contains marker; false if unreadable."""
    try:
        with open(path, "r") as f:
            return marker in f.read()
    except:
        return False


def file_skips_asan(path: String) -> Bool:
    """Reports whether a source file contains the `# SKIP_ASAN` marker."""
    return file_contains(path, "# SKIP_ASAN")


def file_skips_debug(path: String) -> Bool:
    """Reports whether a source file contains the `# SKIP_DEBUG` marker."""
    return file_contains(path, "# SKIP_DEBUG")


def asan_reported(result: ProcessResult) -> Bool:
    """Detects ASAN reports in output, even when the exit status is zero."""
    var output = result.stdout + result.stderr
    return "ERROR:" in output and "AddressSanitizer" in output


def mark_asan_failure(var result: ProcessResult) -> ProcessResult:
    """Converts an ASAN report into a failed process result."""
    if result.exit_code == 0:
        result.exit_code = 1
    if result.error == "":
        result.error = "AddressSanitizer error detected"
    return result^
