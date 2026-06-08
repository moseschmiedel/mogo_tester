# mogo_tester

`mogo-tester` discovers top-level Mojo files in a directory, compiles each one
with `mojo build`, runs the produced binary, and prints per-file results plus a
final summary. Compiled test binaries run with fake TTY-backed stdout and stderr
so terminal-aware test output behaves as it would in an interactive terminal.

## Requirements

- Go 1.26.3 or newer
- Mojo on `PATH`
- `clang` on `PATH` when using `--asan`

## Run

```sh
go run ./cmd/mogo-tester [OPTION...] TEST-DIR
```

Useful flags:

```text
--parallel N              maximum concurrent compile/run jobs (default: CPU count)
--mojo-build-arg VALUE    extra argument passed to mojo build; repeatable
--mojo-build-args VALUE   space-separated arguments passed to mojo build
--keep-artifacts          keep compiled binaries and print the artifact directory
--no-color                disable colored output
--asan                    build and run tests with AddressSanitizer enabled
--version                 print version and exit
--help                    display help and exit
```

Example:

```sh
go run ./cmd/mogo-tester --parallel 4 --mojo-build-args "-I src" test
```

AddressSanitizer is opt-in:

```sh
go run ./cmd/mogo-tester --asan --mojo-build-args "-I src" test
```

`--asan` requires `clang` so `mogo-tester` can query the compiler resource
directory with `clang --print-resource-dir` and locate the compatible
compiler-rt runtime from there. If you use a non-default compiler, set `CC` to
the `clang` executable to query. Install the runtime with
`pixi add compiler-rt --platform osx-arm64` on Apple silicon macOS or
`pixi add compiler-rt --platform linux-64` on Linux x86_64. To disable ASAN for
one Mojo file, add `# SKIP_ASAN` anywhere in that file.

## Test

```sh
GOCACHE="$PWD/.gocache" go test ./...
```

## Build

```sh
go build -o bin/mogo-tester ./cmd/mogo-tester
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
