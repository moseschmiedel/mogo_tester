# mogo_tester

[![CodeQL](https://github.com/moseschmiedel/mogo_tester/actions/workflows/github-code-scanning/codeql/badge.svg)](https://github.com/moseschmiedel/mogo_tester/actions/workflows/github-code-scanning/codeql)

`mogo-tester` discovers Mojo files from directories or direct file paths,
compiles each one with `mojo build`, runs the produced binary, and prints
per-file results plus a final summary. Compiled test binaries run with fake
TTY-backed stdout and stderr so terminal-aware test output behaves as it would
in an interactive terminal.

It is intended for Mojo projects that organize executable test files in one or
more directories, direct `.mojo` file paths, or a mix of both, and want a single
command that builds and runs each file independently.

## Requirements

- Go 1.26.3 or newer
- Mojo on `PATH`
- `clang` on `PATH` when using `--asan`

## Installation

Install from the `tree-d` prefix.dev channel with Pixi:

```sh
pixi global install --channel https://prefix.dev/tree-d --channel conda-forge mogo-tester
```

Build a local binary from this repository:

```sh
make build
```

The binary is written to `bin/mogo-tester`.

For ad hoc usage without installing the binary:

```sh
go run ./cmd/mogo-tester --help
```

## Usage

```sh
mogo-tester [OPTION...] TEST-PATH...
```

Each `TEST-PATH` must be either a directory or a direct `.mojo` file. Directory
operands contribute top-level `.mojo` files in sorted path order; subdirectories
are not searched. Direct file operands are run in the order provided. The final
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
--keep-artifacts          keep compiled binaries and print the artifact directory
--no-color                disable colored output
--asan                    build and run tests with AddressSanitizer enabled
--version                 print version and exit
--help                    display help and exit
```

Options may appear before or after `TEST-PATH` operands. Use `--` if a test path
itself starts with a dash.

### Examples

```sh
mogo-tester --parallel 4 --mojo-build-args "-I src" test
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
Summary: total=3 passed=2 failed_compile=1 failed_run=0 elapsed=1.23s
```

The process exits with status `0` only when all discovered files compile and
run successfully. Compile failures and run failures both produce a non-zero
exit status.

## Module Precompilation

Use `--precompile PATH` to run `mojo precompile` for one or more Mojo packages
before test compilation starts. For a package path ending in `shared`,
`mogo-tester` writes `shared.mojoc` into the temporary artifact directory and
adds that directory to each later `mojo build` with `-I`.

Duplicate precompile package basenames are rejected because the `.mojoc`
filename defines the package name used by Mojo imports.

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

`mogo-tester` queries `clang --print-resource-dir` to find the compatible
compiler-rt runtime. If you use a non-default compiler, set `CC` to the `clang`
executable to query:

```sh
CC=/path/to/clang mogo-tester --asan test
```

Install the runtime with:

```sh
pixi add compiler-rt --platform osx-arm64
pixi add compiler-rt --platform linux-64
```

To disable ASAN for one Mojo file, add this marker anywhere in the file:

```mojo
# SKIP_ASAN
```

Currently, ASAN runtime lookup is configured for Apple silicon macOS and Linux
x86_64.

## Troubleshooting

### No Tests Found

For directory operands, `mogo-tester` only discovers `.mojo` files directly
inside that directory. Move nested test files to the top level, pass the direct
`.mojo` file path, or run `mogo-tester` against the directory that contains the
file.

### Mojo Build Arguments

`--mojo-build-args` is split on whitespace. If an argument contains spaces or
must be passed as an exact token, use repeated `--mojo-build-arg` flags instead.

To disable the exact debug build argument `-g` for one Mojo file, add this marker
at the top of the file:

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

Run the Go test suite:

```sh
make test
```

Format or tidy changes with standard Go tooling:

```sh
gofmt -w ./cmd ./internal
make tidy
```

For release builds, inject explicit version metadata:

```sh
go build \
  -ldflags "-X main.version=v1.2.3 -X main.commit=$(git rev-parse --short HEAD) -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o bin/mogo-tester \
  ./cmd/mogo-tester
```

If metadata is not injected, `mogo-tester --version` falls back to Go build
metadata from `debug.ReadBuildInfo()` when available.

## Release

Pushing a version tag runs the release workflow, builds Linux, macOS, and
Windows archives, and attaches them to a GitHub Release:

```sh
git tag v2.0.0
git push origin v2.0.0
```
