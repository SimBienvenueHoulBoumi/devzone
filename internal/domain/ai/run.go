package ai

import (
	"context"
	"fmt"
)

// Run executes the `devzone ai` subcommands and returns an exit status.
func Run(ctx context.Context, o Options, args []string) int {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "check":
		Check(ctx, o)
		return 0
	case "rapport":
		Report(ctx, o)
		return 0
	case "first":
		if first := First(ctx, o, Models(ctx, o)); first != "" {
			fmt.Fprintln(o.out(), first)
		}
		return 0
	case "set":
		if err := SetProvider(ctx, o); err != nil {
			return 1
		}
		return 0
	case "unset":
		if err := UnsetProvider(o); err != nil {
			return 1
		}
		return 0
	}
	listModels(ctx, o)
	return 0
}

// listModels prints the detected models and the default one, as the launcher did.
func listModels(ctx context.Context, o Options) {
	names := Models(ctx, o)
	if len(names) == 0 {
		fmt.Fprintf(o.out(), "devzone : no Ollama model detected on %s (answer on /api/tags)\n", o.url())
		return
	}
	fmt.Fprintln(o.out(), "devzone : models detected on the host (Ollama):")
	for _, name := range names {
		fmt.Fprintf(o.out(), "  %s\n", name)
	}
	fmt.Fprintf(o.out(), "default model: %s\n", First(ctx, o, names))
}
