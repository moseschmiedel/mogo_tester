# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- CodeQL scanning and status badge in the README.

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
