package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"

	"github.com/moseschmiedel/mogo_tester/v2/internal/app"
)

var (
	// version, commit, and date are populated by release builds through
	// -ldflags. Local builds keep these defaults and may fall back to Go build
	// metadata instead.
	version = "dev"
	commit  = "unknown"
	date    = "unknown"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	if err := app.Run(ctx, os.Args[1:], os.Stdout, logger, resolvedVersion()); err != nil {
		logger.Error("application failed", "error", err)
		os.Exit(1)
	}
}

// resolvedVersion returns the version string shown by --version, preferring
// release-time ldflags and falling back to embedded Go VCS metadata when
// available.
func resolvedVersion() string {
	v := version
	c := commit
	d := date
	info, ok := debug.ReadBuildInfo()
	if ok {
		if c == "" || c == "unknown" {
			c = buildSetting(info, "vcs.revision", c)
		}
		if d == "" || d == "unknown" {
			d = buildSetting(info, "vcs.time", d)
		}
	}

	if version != "" && version != "dev" {
		return formatVersion(v, c, d)
	}

	if !ok || info.Main.Version == "" || info.Main.Version == "(devel)" {
		return formatVersion("dev", c, d)
	}
	v = info.Main.Version
	return formatVersion(v, c, d)
}

// buildSetting returns a single debug build setting, or fallback when the
// setting is absent from the current binary.
func buildSetting(info *debug.BuildInfo, key, fallback string) string {
	for _, setting := range info.Settings {
		if setting.Key == key && setting.Value != "" {
			return setting.Value
		}
	}
	return fallback
}

// formatVersion joins the semantic version with optional commit and build date
// metadata while omitting empty or unknown fields.
func formatVersion(version, commit, date string) string {
	fields := []string{version}
	if commit != "" && commit != "unknown" {
		fields = append(fields, fmt.Sprintf("commit=%s", commit))
	}
	if date != "" && date != "unknown" {
		fields = append(fields, fmt.Sprintf("date=%s", date))
	}
	return strings.Join(fields, " ")
}
