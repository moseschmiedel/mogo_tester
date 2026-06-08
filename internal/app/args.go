package app

import (
	"flag"
	"fmt"
	"io"
	"runtime"
	"strings"
)

type config struct {
	testDir       string
	parallel      int
	mojoBuildArgs []string
	keepArtifacts bool
	noColor       bool
	showVersion   bool
	asan          bool
	asanRuntime   asanRuntime
}

type repeatableStrings []string

// String implements flag.Value for repeatable string flags.
func (r *repeatableStrings) String() string {
	return strings.Join(*r, ",")
}

// Set appends one flag occurrence to the accumulated values.
func (r *repeatableStrings) Set(value string) error {
	*r = append(*r, value)
	return nil
}

// parseArgs converts CLI arguments into runtime configuration and validates
// user-facing constraints such as the required test directory and parallelism.
func parseArgs(args []string, output io.Writer) (config, error) {
	cfg := config{parallel: runtime.NumCPU()}
	var mojoBuildArgs string

	flags := flag.NewFlagSet("mogo-tester", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.Usage = func() {
		printUsage(output, cfg.parallel)
	}
	flags.IntVar(&cfg.parallel, "parallel", cfg.parallel, "maximum number of tests to compile and run concurrently")
	flags.Var((*repeatableStrings)(&cfg.mojoBuildArgs), "mojo-build-arg", "additional argument passed to mojo build; may be repeated")
	flags.StringVar(&mojoBuildArgs, "mojo-build-args", "", "space-separated arguments passed to mojo build")
	flags.BoolVar(&cfg.keepArtifacts, "keep-artifacts", false, "keep compiled binaries and print the artifact directory")
	flags.BoolVar(&cfg.noColor, "no-color", false, "disable colored output")
	flags.BoolVar(&cfg.asan, "asan", false, "build and run tests with AddressSanitizer enabled")
	flags.BoolVar(&cfg.showVersion, "version", false, "print version and exit")

	if err := flags.Parse(reorderOptions(args)); err != nil {
		return config{}, err
	}

	if cfg.parallel < 1 {
		return config{}, fmt.Errorf("parallel must be >= 1")
	}

	cfg.mojoBuildArgs = append(cfg.mojoBuildArgs, strings.Fields(mojoBuildArgs)...)

	remaining := flags.Args()
	if cfg.showVersion {
		if len(remaining) > 1 {
			return config{}, fmt.Errorf("usage: mogo-tester [options] <test-dir>")
		}
		return cfg, nil
	}

	if len(remaining) != 1 {
		return config{}, fmt.Errorf("usage: mogo-tester [options] <test-dir>")
	}

	cfg.testDir = remaining[0]
	return cfg, nil
}

// reorderOptions accepts options before or after TEST-DIR by moving all options
// before a synthetic "--" delimiter, while preserving operands as directory
// arguments.
func reorderOptions(args []string) []string {
	valueOptions := map[string]bool{
		"parallel":        true,
		"mojo-build-arg":  true,
		"mojo-build-args": true,
	}

	var options []string
	var operands []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			operands = append(operands, args[i+1:]...)
			break
		}
		if !isOption(arg) {
			operands = append(operands, arg)
			continue
		}

		options = append(options, arg)
		name, hasInlineValue := optionName(arg)
		if valueOptions[name] && !hasInlineValue && i+1 < len(args) {
			i++
			options = append(options, args[i])
		}
	}

	if len(operands) == 0 {
		return options
	}
	normalized := make([]string, 0, len(options)+1+len(operands))
	normalized = append(normalized, options...)
	normalized = append(normalized, "--")
	normalized = append(normalized, operands...)
	return normalized
}

// isOption reports whether arg should be treated as an option token.
func isOption(arg string) bool {
	return strings.HasPrefix(arg, "-") && arg != "-"
}

// optionName returns the normalized option name and whether it used --name=value
// syntax.
func optionName(arg string) (string, bool) {
	name := strings.TrimLeft(arg, "-")
	beforeValue, _, hasValue := strings.Cut(name, "=")
	if hasValue {
		return beforeValue, true
	}
	return name, false
}

// printUsage writes the command help text with the platform-specific default
// parallelism value.
func printUsage(output io.Writer, defaultParallel int) {
	fmt.Fprintf(output, "Usage: mogo-tester [OPTION...] TEST-DIR\n\n")
	fmt.Fprintf(output, "Compile and run top-level Mojo test files in TEST-DIR.\n\n")
	fmt.Fprintf(output, "Options:\n")
	fmt.Fprintf(output, "  --parallel N              maximum concurrent compile/run jobs (default: %d)\n", defaultParallel)
	fmt.Fprintf(output, "  --mojo-build-arg VALUE    extra argument passed to mojo build; may be repeated\n")
	fmt.Fprintf(output, "  --mojo-build-args VALUE   space-separated arguments passed to mojo build\n")
	fmt.Fprintf(output, "  --keep-artifacts          keep compiled binaries and print the artifact directory\n")
	fmt.Fprintf(output, "  --no-color                disable colored output\n")
	fmt.Fprintf(output, "  --asan                    build and run tests with AddressSanitizer enabled\n")
	fmt.Fprintf(output, "  --version                 print version and exit\n")
	fmt.Fprintf(output, "  --help                    display this help and exit\n")
}
