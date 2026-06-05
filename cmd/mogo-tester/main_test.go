package main

import "testing"

func TestResolvedVersionUsesInjectedVersion(t *testing.T) {
	originalVersion := version
	originalCommit := commit
	originalDate := date
	t.Cleanup(func() {
		version = originalVersion
		commit = originalCommit
		date = originalDate
	})

	version = "v1.2.3"
	commit = "abc123"
	date = "2026-06-05T12:00:00Z"
	if got, want := resolvedVersion(), "v1.2.3 commit=abc123 date=2026-06-05T12:00:00Z"; got != want {
		t.Fatalf("resolvedVersion() = %q, want %q", got, want)
	}
}

func TestResolvedVersionFallsBackToDevForLocalBuild(t *testing.T) {
	original := version
	originalCommit := commit
	originalDate := date
	t.Cleanup(func() {
		version = original
		commit = originalCommit
		date = originalDate
	})

	version = "dev"
	commit = "unknown"
	date = "unknown"
	got := resolvedVersion()
	if got == "" {
		t.Fatal("resolvedVersion() = empty string")
	}
}

func TestFormatVersionOmitsUnknownMetadata(t *testing.T) {
	t.Parallel()

	if got, want := formatVersion("dev", "unknown", "unknown"), "dev"; got != want {
		t.Fatalf("formatVersion() = %q, want %q", got, want)
	}
}
