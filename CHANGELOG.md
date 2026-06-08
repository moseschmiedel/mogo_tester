# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- Documented that `clang` is required for AddressSanitizer runtime discovery
  when using `--asan`.
- Expanded the README with installation, usage, output, exit status,
  AddressSanitizer, troubleshooting, and development guidance.
- Added Go doc comments and package documentation for the main application
  flow, argument parsing, runner, reporting, command execution, and
  AddressSanitizer helpers.

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
