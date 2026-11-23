# mogo_tester

`mogo-tester` discovers Mojo files from directories or direct file paths,
compiles each one with `mojo build`, runs the produced binary, and prints
per-file results plus a final summary. Compiled test binaries run with fake
TTY-backed stdout and stderr so terminal-aware test output behaves as it would
in an interactive terminal.

It is intended for Mojo projects that organize executable test files in one or
more directories, direct `.mojo` file paths, or a mix of both, and want a single
command that builds and runs each file independently.

## Requirements

- macOS on Apple silicon or Linux (x86_64 or aarch64)
- Mojo on `PATH`
- `clang` on `PATH` when using `--asan`

`mogo-tester` is written in Mojo 1.2. Mojo binaries link the Mojo runtime
library dynamically, so the tool is distributed as a conda package that
depends on `mojo-compiler`, not as a standalone binary.

## Installation

Install from the `tree-d` prefix.dev channel with Pixi:

```sh
pixi global install \
  --channel https://prefix.dev/tree-d \
  --channel https://conda.modular.com/max \
  --channel conda-forge \
  mogo-tester
```

The package requires Mojo 1.2 for its own runtime, but it compiles tests with
whichever `mojo` is first on `PATH`. To test a project on another Mojo version,
install `mogo-tester` in a separate Pixi environment:

```toml
[feature.test-runner.dependencies]
mogo-tester = ">=3.1.1,<4"

[environments]
test-runner = { features = ["test-runner"], no-default-feature = true }
```

Then run that binary from the project's environment:

```sh
pixi install -e test-runner
pixi run -e test "$PWD/.pixi/envs/test-runner/bin/mogo-tester" tests
```

The `linux-64` package targets `x86-64-v3`, so the CPU must support AVX2.

Build a local binary from this repository with [Pixi](https://pixi.sh):

```sh
make build
```

The binary is written to `bin/mogo-tester`. It loads the Mojo runtime from the
repository's `.pixi` environment.

On Linux, `mojo build` links through the system C compiler, so `cc` (for
example `gcc`) must be on `PATH`.

## Usage

```sh
mogo-tester [OPTION...] [TEST-PATH...]
```

Each `TEST-PATH` must be either a directory or a direct `.mojo` file. Directory
operands contribute top-level `.mojo` files in sorted path order; subdirectories
are not searched unless `--recursive` is given, in which case every `.mojo` file
below the directory is included, sorted by path. Symlinked subdirectories are
not followed. A directory operand that contributes no files produces a warning
on stderr. Direct file operands are run in the order provided. The final
test file list is compiled and run with up to `--parallel` workers.

Each test file is compiled with:

```sh
mojo build [MOJO-BUILD-ARGS...] [-I PRECOMPILE-ARTIFACT-DIR] -o ARTIFACT TEST-FILE
```

If compilation succeeds, `mogo-tester` runs the compiled artifact. A compile
failure skips the run step for that file.

### Options

```text
--parallel N              maximum concurrent compile/run jobs (default: CPU count)
--mojo-build-arg VALUE    extra argument passed to mojo build; repeatable
--mojo-build-args VALUE   space-separated arguments passed to mojo build
--precompile PATH         precompile Mojo package before building tests; repeatable
--doctests PATH           run doctests from .mojo and .md files under PATH; repeatable
--exclude GLOB            skip test files matching GLOB; repeatable
--keep-artifacts          keep compiled binaries and print the artifact directory
--recursive               search directory operands recursively
--no-color                disable colored output
--asan                    build and run tests with AddressSanitizer enabled
--version                 print version and exit
--help                    display help and exit
```

Options may appear before or after `TEST-PATH` operands. Use `--` if a test path
itself starts with a dash. `TEST-PATH` operands are optional when `--doctests`
is given.

### Examples

```sh
mogo-tester --parallel 4 --mojo-build-args "-I src" test
```

Run every `.mojo` file in a nested test tree:

```sh
mogo-tester --recursive docs/test
```

Run specific files:

```sh
mogo-tester test/basic.mojo test/integration.mojo
```

Mix directories and direct files:

```sh
mogo-tester test smoke/single.mojo
```

Prefer repeated `--mojo-build-arg` flags when arguments need exact shell-safe
token boundaries:

```sh
mogo-tester test --mojo-build-arg -I --mojo-build-arg src
```

Keep compiled binaries for inspection:

```sh
mogo-tester --keep-artifacts test
```

Precompile a shared Mojo package before compiling tests that import it:

```sh
mogo-tester --precompile src/shared --mojo-build-args "-I src" test
```

Run the doctests in a package's docstrings and guide pages next to the tests:

```sh
mogo-tester --mojo-build-args "-I src" --doctests src/mypkg --doctests docs test
```

Skip known-failing files without deleting them:

```sh
mogo-tester --recursive \
  --exclude readme_test.mojo \
  --exclude 'docs/test/**/host_storage_*_test.mojo' \
  docs/test
```

Disable ANSI color codes for logs or CI output:

```sh
mogo-tester --no-color test
```

## Output And Exit Status

During a run, `mogo-tester` prints progress for files currently compiling
(`C`) and running (`R`). On an interactive terminal this progress line is
updated in place; when output is redirected, progress lines are printed as
ordinary lines.

Each file gets a result block containing:

- The full `mojo build` command.
- Compile status, exit code, duration, stdout, and stderr.
- Run status, exit code, duration, and output when compilation succeeded.
- A final per-file `PASS` or `FAIL`.

The final line is a machine-readable summary:

```text
Summary: total=3 passed=2 failed_compile=1 failed_run=0 elapsed=1.23s skipped=0
```

`skipped` counts files excluded with `--exclude`; they are not included in
`total`.

The process exits with status `0` only when all discovered files compile and
run successfully. Compile failures and run failures both produce a non-zero
exit status.

Pressing Ctrl-C kills the running compile and test processes, including any
processes they started, prints the summary for the files that finished,
removes the artifact directory, and exits with status `1`. Further Ctrl-C
presses are ignored during this shutdown.

A test that starts background processes finishes when the test binary itself
exits. Output that those background processes write afterwards is not
captured.

## Module Precompilation

Use `--precompile PATH` to run `mojo precompile` for one or more Mojo packages
before test compilation starts. For a package path ending in `shared`,
`mogo-tester` writes `shared.mojoc` into the temporary artifact directory and
adds that directory to each later `mojo build` with `-I`.

Duplicate precompile package basenames are rejected because the `.mojoc`
filename defines the package name used by Mojo imports.

## Doctests

`--doctests PATH` collects Mojo code blocks from Markdown files and from
docstrings in `.mojo` files. A directory is searched recursively, skipping
entries whose name starts with `.`. A block takes part when its fence carries
a `doctest` attribute, using the same syntax as
[Modo](https://mlange-42.github.io/modo/):

````markdown
```mojo {doctest="greet" global=true hide=true}
from std.testing import assert_equal
```

```mojo {doctest="greet"}
assert_equal("hi".upper(), "HI")
```
````

Blocks with the same `doctest` name in one Markdown file, or in one docstring,
form a single program:

- Blocks marked `global=true` are placed at file scope, in source order.
- All other blocks become the body of a generated `def main() raises:`.
- If the global blocks define `def main` themselves and no other blocks
  exist, the program is used unchanged. Combining such a `main` with
  non-global blocks is reported as a failure.
- `hide` only affects rendered documentation and is ignored.

Each doctest is compiled and run like a test file and reported as
`SOURCE:LINE#NAME`. Compiler diagnostics refer to lines in the documentation
source rather than the generated program. A directory that contains no
doctests is an error.

## AddressSanitizer

AddressSanitizer is opt-in:

```sh
mogo-tester --asan --mojo-build-args "-I src" test
```

When `--asan` is enabled, each eligible test is built with:

```text
--sanitize address --external-libasan PATH-TO-RUNTIME
```

The compiled binary is then run with the platform preload variable pointing at
the same runtime:

- macOS arm64: `DYLD_INSERT_LIBRARIES`
- Linux x86_64: `LD_PRELOAD`

`mogo-tester` queries `clang --print-resource-dir` to find the compatible clang runtime libraries. If you use a non-default compiler, set `CC` to the `clang`
executable to query:

```sh
CC=/path/to/clang mogo-tester --asan test
```

Install the runtime with:

```sh
pixi add clang --platform osx-arm64
pixi add clang --platform linux-64
```

To disable ASAN for one Mojo file, add this marker to the comment header at
the top of the file:

```mojo
# SKIP_ASAN
```

The comment header is the run of lines at the start of the file that are blank
or start with `#`. `mogo-tester` stops reading at the first other line, so a
marker after that line has no effect.

Currently, ASAN runtime lookup is configured for `aarch64-apple-macosx` and
`x86_64-unknown-linux-gnu`.

## Troubleshooting

### No Tests Found

For directory operands, `mogo-tester` only discovers `.mojo` files directly
inside that directory by default. Pass `--recursive` to include nested files,
pass the direct `.mojo` file path, or run `mogo-tester` against the directory
that contains the file. A directory operand without any discovered files is
reported with a warning such as:

```text
WARNING::: no .mojo files found in docs/test (use --recursive to search subdirectories)
```

### Excluding Files

`--exclude GLOB` removes discovered test files from the run. It does not apply
to doctests selected with `--doctests`. Each excluded file is
printed as `SKIP PATH` before the result blocks, is neither compiled nor run,
and does not affect the exit status.

A pattern matches if it matches either the discovered path, after redundant
`./` and `//` are removed, or the file's basename. Patterns are matched against
paths as discovered, so use relative patterns with relative operands. Within a
path element, `*` matches any characters, `?` matches one character, and
`[...]` matches a character class (`[a-z]`, `[!a-z]`). A `**` element matches
zero or more directories. If a pattern matches no file, `mogo-tester` logs a
warning, which helps spot stale skip lists:

```text
WARNING::: --exclude pattern gone_test.mojo matched no test files
```

### Mojo Build Arguments

`--mojo-build-args` is split on whitespace. If an argument contains spaces or
must be passed as an exact token, use repeated `--mojo-build-arg` flags instead.

Add a `# MOJO_BUILD_ARGS:` line to a test file's comment header to pass flags
to `mojo build` for that file. Both forms below select line-table debug
information.

```mojo
# MOJO_BUILD_ARGS: -g1
# MOJO_BUILD_ARGS: --debug-level line-tables
```

Like `--mojo-build-args`, the marker splits flags on whitespace. Repeat the
marker to append flags in header order. The file's flags follow suite-wide
flags, so Mojo uses the per-file value for options such as the debug level.

Add `# SKIP_DEBUG` to the comment header to drop the exact suite-wide `-g`
argument for that file.

```mojo
# SKIP_DEBUG
```

This is useful for files affected by Mojo debug-build bugs. Other build
arguments are preserved exactly and in order.

### Missing ASAN Runtime

If `--asan` cannot find a runtime, check the compiler being queried:

```sh
clang --print-resource-dir
```

Then verify that the compiler resource directory contains the relevant
`libclang_rt.asan...` runtime below its `lib` directory. If the project uses a
toolchain-managed compiler, set `CC` to that compiler before running
`mogo-tester`.

## Development

Run the test suite. `make test` builds `bin/mogo-tester` and uses it to run
the Mojo test files in `tests/`:

```sh
make test
```

Format Mojo sources:

```sh
make format
```

Release builds inject version metadata with Mojo defines:

```sh
make build VERSION=v1.2.3
```

`make build` sets `MOGO_COMMIT` from `git rev-parse --short HEAD` and
`MOGO_DATE` from the current UTC time. Without `VERSION`, `--version` reports
`dev`.

## Release

Pushing a version tag runs the release workflow. It builds and uploads the
conda packages for `linux-64` and `osx-arm64` to the `tree-d` prefix.dev
channel, then creates a GitHub Release without attached binaries:

```sh
git tag v3.0.0
git push origin v3.0.0
```
