# AGENTS.md

Guidance for agents working in this repository.

## Project

`mogo-tester` is a Mojo 1.2 CLI that discovers top-level `.mojo` files in a
directory, compiles each with `mojo build`, runs the produced binary, and
reports per-file results plus an aggregate summary. Runtime behavior lives in
the `src/mogo_tester` package; the CLI entry point is `src/main.mojo`. The Mojo
toolchain is managed by Pixi (`pixi.toml`).

## Common Commands

- Build: `make build`
- Test: `make test` (builds `bin/mogo-tester`, then runs `tests/` with it)
- Run one test file: `pixi run mojo run -I src tests/test_args.mojo`
- Format Mojo code: `make format`

`tests/test_cli.mojo` runs the built binary against a fake `mojo` script on
`PATH`; set `MOGO_TESTER_BIN` to test a different binary.

## Documentation

- Keep user-facing CLI behavior in `README.md`.
- Record notable changes in `CHANGELOG.md` under `## [Unreleased]` until a
  release is prepared.
- Mojo docstrings follow the Mojo docstring style: one-line summary, then
  details. Module docstrings open each file.

## Release Process

Latest known release: `v2.3.3`.

To prepare the next patch release:

1. Move current `CHANGELOG.md` Unreleased entries under a dated version heading,
   for example `## [2.2.2] - YYYY-MM-DD`.
2. Bump `recipe/recipe.yaml` `context.version` to the same version without the
   leading `v`.
3. Run `make test`.
4. Commit the release prep, for example `git commit -m "Release v2.2.2"`.
5. Tag the release, for example `git tag v2.2.2`.
6. Push `main`, then push the tag.

The GitHub Actions workflow `.github/workflows/ci-release.yml` runs when a
`v*` tag is pushed. It builds the conda packages from
`recipe/recipe-mojo-community.yaml`, uploads them to the `tree-d` prefix.dev
channel, and then creates a GitHub Release without binaries. Mojo binaries
link the Mojo runtime dynamically, so standalone archives are not published.

Keep the `mojo-compiler` pin in the recipes in sync with `pixi.toml`.

After pushing a tag, check the workflow with:

```sh
gh run list --repo moseschmiedel/mogo_tester --limit 10
gh run watch RUN_ID --repo moseschmiedel/mogo_tester --exit-status
gh release view TAG --repo moseschmiedel/mogo_tester
```


## Implementation Notes

- Test discovery is intentionally top-level only; nested `.mojo` files are not
  searched.
- Test paths are sorted before execution.
- `--mojo-build-arg` is repeatable and preserves exact tokens.
- `--mojo-build-args` is split with `strings.Fields`.
- Compiled artifacts use sanitized basenames plus a path hash to avoid
  collisions.
- `src/mogo_tester/libc.mojo` holds only direct, `@inline(.always)`
  translations of libc functions and constants. Abstractions built on them
  live in their own modules: `fd` (pipes, reads, `PollSet`), `pty`, `spawn`
  (`posix_spawn`, `look_path`, process groups), `signals`
  (`InterruptGuard`), and `env` (`Environment`). `cffi` holds the pointer
  glue.
- Raw pointers from `cffi.addr`/`cstr` carry no origin and do not keep their
  owner alive. Use the owning value again after the C call (`_ = value^`)
  when nothing else does, or Mojo may free it before the call reads it.
- Use `std.pathlib.Path` for filesystem paths. `paths.clean` adds the lexical
  normalization (`filepath.Clean`) that `Path` lacks.
- Prefer `out` result arguments over building a local and returning it with
  `^`.
- Parallel jobs run in a single-threaded `poll` loop.
- Each child runs in its own process group with an empty signal mask and
  default SIGINT handling. Ctrl-C kills the child process groups.
- SIGINT handling cannot block the signal (the Mojo runtime starts threads
  before `main`) or set a flag (Mojo has no globals, and fixed descriptors
  fail under low `ulimit -n`). The one-shot handler sets SIGINT's
  disposition to `SIG_IGN`, and `InterruptGuard.interrupted()` queries it.
- A child is finished once it has exited: buffered output is drained, but
  the run does not wait for EOF from descendants that inherited its stdout
  or stderr.
- Test binaries run with PTY-backed combined output when supported, falling back
  to ordinary pipes if PTYs are unsupported.
- `external_call` declarations must match the stdlib's own declarations of the
  same libc symbol (pointer vs. integer types), or compilation fails with
  "existing function with conflicting signature".
- `--asan` uses `clang --print-resource-dir` or `CC` when set to locate the
  compatible AddressSanitizer runtime.
- ASAN runtime lookup is configured for `aarch64-apple-macosx` and
  `x86_64-unknown-linux-gnu`. Platforms are the `Platform` enum, written as
  Mojo target triples.
- Version metadata comes from `-D MOGO_VERSION`, `-D MOGO_COMMIT`, and
  `-D MOGO_DATE`.
- `# SKIP_ASAN` and `# SKIP_DEBUG` are read from the comment header only
  (`markers.read_markers`), so marker lookup does not read whole files.
- Diagnostics go through `std.logger` on stderr (`app.logger()`).
