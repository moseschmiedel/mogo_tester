# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- **Breaking:** Rewrote `mogo-tester` in Mojo 1.2. The CLI options, report
  format, and exit status are unchanged. The tool now requires macOS on Apple
  silicon or Linux; Windows and Intel macOS are no longer supported.
- **Breaking:** Releases are distributed only as conda packages on the
  `tree-d` prefix.dev channel, which now depend on `mojo-compiler` from
  `https://conda.modular.com/max`. GitHub Releases no longer attach binary
  archives.
- Ctrl-C now also kills processes started by compile and test processes.
- Version metadata is injected with `-D MOGO_VERSION=...`,
  `-D MOGO_COMMIT=...`, and `-D MOGO_DATE=...` instead of Go linker flags.
- **Breaking:** `# SKIP_ASAN` and `# SKIP_DEBUG` are only recognized in the
  comment header at the top of a file (leading blank or `#` lines).
  `# SKIP_ASAN` was previously recognized anywhere in the file.
- Diagnostics on stderr use the Mojo standard library logger, for example
  `INFO::: running mojo tests ...` and `ERROR::: application failed: ...`,
  instead of Go `slog` key-value records.
- Platform names in ASAN errors use Mojo target triples, such as
  `x86_64-unknown-linux-gnu`.

### Removed

- CodeQL scanning and its README badge. CodeQL cannot analyze Mojo sources.

## [2.3.3] - 2026-06-15

### Fixed

- Prevented conda package artifact directories from being uploaded as GitHub
  Release assets.

## [2.3.2] - 2026-06-15

### Added

- CodeQL scanning and status badge in the README.
- Published tagged releases to the `tree-d` prefix.dev channel.

## [2.3.1] - 2026-06-10

### Changed

- Printed `mojo precompile` command output in the same report block format as
  compile and run output, including captured stderr.

## [2.3.0] - 2026-06-10

### Added

- Allowed one or more test path operands, including direct `.mojo` files and
  mixed directory/file invocations.
- Added a repeatable `--precompile` option that runs `mojo precompile` for
  shared packages before compiling tests.
- Added a `# SKIP_DEBUG` source marker for omitting exact `-g` Mojo build
  arguments on affected files, addressing issue #1.

## [2.2.1] - 2026-06-08

### Changed

- Documented that `clang` is required for AddressSanitizer runtime discovery
  when using `--asan`.
- Expanded the README with installation, usage, output, exit status,
  AddressSanitizer, troubleshooting, and development guidance.
- Added Go doc comments and package documentation for the main application
  flow, argument parsing, runner, reporting, command execution, and
  AddressSanitizer helpers, following the current Go doc comment guide.

## [2.2.0] - 2026-06-05

### Added

- Added AddressSanitizer support for Mojo test runs with the `--asan` flag.
- Added a live progress line for parallel test runs.

## [2.1.0] - 2026-06-05

### Added

- Added PTY-backed test execution output capture for terminal color support.

## [2.0.0] - 2026-06-05

### Added

- Added the initial `mogo-tester` command-line application for discovering,
  compiling, running, and summarizing Mojo tests.
