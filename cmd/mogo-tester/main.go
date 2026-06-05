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

func buildSetting(info *debug.BuildInfo, key, fallback string) string {
	for _, setting := range info.Settings {
		if setting.Key == key && setting.Value != "" {
			return setting.Value
		}
	}
	return fallback
}

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
