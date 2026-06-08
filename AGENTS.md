# AGENTS.md

Guidance for agents working in this repository.

## Project

`mogo-tester` is a Go CLI that discovers top-level `.mojo` files in a directory,
compiles each with `mojo build`, runs the produced binary, and reports per-file
results plus an aggregate summary. Runtime behavior lives under `internal/app`;
the CLI entry point is `cmd/mogo-tester`.

## Common Commands

- Build: `make build`
- Test: `make test`
- Tidy dependencies: `make tidy`
- Format Go code: `gofmt -w ./cmd ./internal`
- Render package docs: `go doc ./internal/app`
- Render command docs: `go doc ./cmd/mogo-tester`

The Makefile sets `GOCACHE=$(CURDIR)/.gocache` so tests and builds avoid global
cache writes.

## Documentation

- Keep user-facing CLI behavior in `README.md`.
- Record notable changes in `CHANGELOG.md` under `## [Unreleased]` until a
  release is prepared.
- Go doc comments should follow the current official guide:
  https://go.dev/doc/comment
- Package comments live in:
  - `cmd/mogo-tester/doc.go`
  - `internal/app/doc.go`
- For command package comments, start with the capitalized command name, for
  example `Mogo-tester ...`, not `Command mogo-tester ...`.

## Release Process

Latest known release: `v2.2.1`.

To prepare the next patch release:

1. Move current `CHANGELOG.md` Unreleased entries under a dated version heading,
   for example `## [2.2.2] - YYYY-MM-DD`.
2. Bump `recipe/recipe.yaml` `context.version` to the same version without the
   leading `v`.
3. Run `make test`.
4. Commit the release prep, for example `git commit -m "Release v2.2.2"`.
5. Tag the release, for example `git tag v2.2.2`.
6. Push `main`, then push the tag.

The GitHub Actions workflow `.github/workflows/ci-release.yml` creates the
GitHub Release when a `v*` tag is pushed. It builds archives for Linux, macOS,
and Windows and attaches them to the release.

After pushing a tag, check the workflow with:

```sh
gh run list --repo moseschmiedel/mogo_tester --limit 10
gh run watch RUN_ID --repo moseschmiedel/mogo_tester --exit-status
gh release view TAG --repo moseschmiedel/mogo_tester
```

GitHub Actions currently emits Node.js 20 deprecation warnings for the existing
workflow actions. These warnings did not block the `v2.2.1` release.

## Implementation Notes

- Test discovery is intentionally top-level only; nested `.mojo` files are not
  searched.
- Test paths are sorted before execution.
- `--mojo-build-arg` is repeatable and preserves exact tokens.
- `--mojo-build-args` is split with `strings.Fields`.
- Compiled artifacts use sanitized basenames plus a path hash to avoid
  collisions.
- Test binaries run with PTY-backed combined output when supported, falling back
  to ordinary pipes if PTYs are unsupported.
- `--asan` uses `clang --print-resource-dir` or `CC` when set to locate the
  compatible AddressSanitizer runtime.
- ASAN runtime lookup is configured for `darwin/arm64` and `linux/amd64`.
- A source file containing `# SKIP_ASAN` opts out of ASAN for that file.
