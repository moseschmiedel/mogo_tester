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
- Process handling uses libc through `external_call` in
  `src/mogo_tester/libc.mojo`: `posix_spawnp` with file actions, PTYs from
  `posix_openpt`, and a single-threaded `poll` loop for parallel jobs.
- Each child runs in its own process group with an empty signal mask. The
  parent blocks SIGINT and checks `sigpending` in the poll loop, then kills
  the child process groups.
- Test binaries run with PTY-backed combined output when supported, falling back
  to ordinary pipes if PTYs are unsupported.
- `external_call` declarations must match the stdlib's own declarations of the
  same libc symbol (pointer vs. integer types), or compilation fails with
  "existing function with conflicting signature".
- `--asan` uses `clang --print-resource-dir` or `CC` when set to locate the
  compatible AddressSanitizer runtime.
- ASAN runtime lookup is configured for `darwin/arm64` and `linux/amd64`.
- Version metadata comes from `-D MOGO_VERSION`, `-D MOGO_COMMIT`, and
  `-D MOGO_DATE`.
- A source file containing `# SKIP_ASAN` opts out of ASAN for that file.
