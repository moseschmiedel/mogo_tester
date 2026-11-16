"""Command-line parsing."""

from std.pathlib import Path
from std.sys import num_logical_cores

from .asan import ASANRuntime


struct Config(Copyable, Movable):
    """Runtime configuration derived from command-line arguments."""

    var test_paths: List[Path]
    var parallel: Int
    var mojo_build_args: List[String]
    var precompile_paths: List[Path]
    var keep_artifacts: Bool
    var no_color: Bool
    var show_version: Bool
    var show_help: Bool
    var asan: Bool
    var asan_runtime: ASANRuntime
    var precompile_import_dir: Optional[Path]

    def __init__(out self):
        self.test_paths = List[Path]()
        self.parallel = num_logical_cores()
        self.mojo_build_args = List[String]()
        self.precompile_paths = List[Path]()
        self.keep_artifacts = False
        self.no_color = False
        self.show_version = False
        self.show_help = False
        self.asan = False
        self.asan_runtime = ASANRuntime()
        self.precompile_import_dir = None


comptime VALUE_OPTIONS: List[String] = [
    "parallel",
    "mojo-build-arg",
    "mojo-build-args",
    "precompile",
]
comptime BOOL_OPTIONS: List[String] = [
    "keep-artifacts",
    "no-color",
    "asan",
    "version",
]


@fieldwise_init
struct UsageError(Copyable, Movable, Writable):
    """A command-line error. `show_usage` requests printing the help text
    before the error is reported, as for unknown options."""

    var message: String
    var show_usage: Bool

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.message)


def is_option(arg: String) -> Bool:
    """Reports whether arg should be treated as an option token."""
    return arg.startswith("-") and arg != "-"


def option_name(arg: String) -> Tuple[String, Bool]:
    """Returns the option name without leading dashes and whether the token
    used `--name=value` syntax."""
    var name = String(arg.lstrip("-"))
    var index = name.find("=")
    if index >= 0:
        return (String(name[byte=0:index]), True)
    return (name^, False)


def _inline_value(arg: String) -> String:
    var index = arg.find("=")
    return String(arg[byte = index + 1 : arg.byte_length()])


def _parse_bool(name: String, value: String) raises UsageError -> Bool:
    if (
        value == "1"
        or value == "t"
        or value == "T"
        or value == "true"
        or value == "TRUE"
        or value == "True"
    ):
        return True
    if (
        value == "0"
        or value == "f"
        or value == "F"
        or value == "false"
        or value == "FALSE"
        or value == "False"
    ):
        return False
    raise UsageError(
        String(
            'invalid boolean value "', value, '" for -', name, ": parse error"
        ),
        True,
    )


def _parse_int(name: String, value: String) raises UsageError -> Int:
    try:
        return atol(value)
    except:
        raise UsageError(
            String(
                'invalid value "', value, '" for flag -', name, ": parse error"
            ),
            True,
        )


def parse_args(args: List[String], out cfg: Config) raises UsageError:
    """Converts CLI arguments into configuration.

    Options may appear before or after test path operands; `--` ends option
    parsing. A value option consumes the next token even if it starts with a
    dash, so `--mojo-build-arg -g` works.
    """
    cfg = Config()
    var split_build_args = List[String]()
    var i = 0
    while i < len(args):
        var arg = args[i]
        i += 1
        if arg == "--":
            while i < len(args):
                cfg.test_paths.append(Path(args[i]))
                i += 1
            break
        if not is_option(arg):
            cfg.test_paths.append(Path(arg))
            continue

        var parsed = option_name(arg)
        var name = parsed[0]
        var has_inline = parsed[1]

        if name == "h" or name == "help":
            cfg.show_help = True
            return

        if name in materialize[VALUE_OPTIONS]():
            var value: String
            if has_inline:
                value = _inline_value(arg)
            elif i < len(args):
                value = args[i]
                i += 1
            else:
                raise UsageError(
                    String("flag needs an argument: -", name), True
                )
            if name == "parallel":
                cfg.parallel = _parse_int(name, value)
            elif name == "mojo-build-arg":
                cfg.mojo_build_args.append(value)
            elif name == "mojo-build-args":
                # The last occurrence wins, as with a plain string flag.
                split_build_args.clear()
                for field in value.split():
                    split_build_args.append(String(field))
            else:
                cfg.precompile_paths.append(Path(value))
            continue

        if name in materialize[BOOL_OPTIONS]():
            var enabled = True
            if has_inline:
                enabled = _parse_bool(name, _inline_value(arg))
            if name == "keep-artifacts":
                cfg.keep_artifacts = enabled
            elif name == "no-color":
                cfg.no_color = enabled
            elif name == "asan":
                cfg.asan = enabled
            else:
                cfg.show_version = enabled
            continue

        raise UsageError(String("flag provided but not defined: -", name), True)

    if cfg.parallel < 1:
        raise UsageError("parallel must be >= 1", False)

    for value in split_build_args:
        cfg.mojo_build_args.append(value)

    if cfg.show_version:
        return

    if len(cfg.test_paths) == 0:
        raise UsageError("usage: mogo-tester [options] <test-path>...", False)


def usage(default_parallel: Int) -> String:
    """Returns the help text with the platform default parallelism."""
    return String(
        "Usage: mogo-tester [OPTION...] TEST-PATH...\n\n",
        (
            "Compile and run Mojo test files from directories or direct .mojo"
            " files.\n\n"
        ),
        "Options:\n",
        (
            "  --parallel N              maximum concurrent compile/run jobs"
            " (default: "
        ),
        default_parallel,
        ")\n",
        (
            "  --mojo-build-arg VALUE    extra argument passed to mojo build;"
            " may be repeated\n"
        ),
        (
            "  --mojo-build-args VALUE   space-separated arguments passed to"
            " mojo build\n"
        ),
        (
            "  --precompile PATH         precompile Mojo package before"
            " building tests; may be repeated\n"
        ),
        (
            "  --keep-artifacts          keep compiled binaries and print the"
            " artifact directory\n"
        ),
        "  --no-color                disable colored output\n",
        (
            "  --asan                    build and run tests with"
            " AddressSanitizer enabled\n"
        ),
        "  --version                 print version and exit\n",
        "  --help                    display this help and exit\n",
    )
