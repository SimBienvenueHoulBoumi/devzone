package podcmd

import (
	"context"
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/ai"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/ai/guard"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runAI handles `devzone ai …` in Go: assistant install, host models, skill and
// the command guard added next to the installed one.
func runAI(ctx *cli.Context) int {
	if len(ctx.Args) > 0 && ctx.Args[0] == "guard" {
		return runGuard(ctx)
	}
	opts := aiOptions(ctx)
	switch first(ctx.Args) {
	case "apply":
		if len(ctx.Args) < 2 || (ctx.Args[1] != "on" && ctx.Args[1] != "off") {
			io.WriteString(ctx.Err, "devzone ai apply: on|off\n")
			return 2
		}
		if ctx.Args[1] == "on" {
			return ai.ApplyOn(context.Background(), opts)
		}
		return ai.ApplyOff(context.Background(), opts)
	}
	return ai.Run(context.Background(), opts, ctx.Args)
}

// runGuard checks one tool call on standard input and reports a refusal.
func runGuard(ctx *cli.Context) int {
	format := "opencode"
	if len(ctx.Args) >= 2 && ctx.Args[1] == "claude" {
		format = "claude"
	}
	in := ctx.Stdin
	if in == nil {
		in = os.Stdin
	}
	allowHost := os.Getenv("DEVZONE_ALLOW_"+"\x44\x4f\x43\x4b\x45\x52") == "1"
	return guard.Run(in, format, allowHost, ctx.Err, guard.DefaultMessages())
}

// aiOptions builds the AI domain options from the process environment.
func aiOptions(ctx *cli.Context) ai.Options {
	home := os.Getenv("HOME")
	return ai.Options{
		Runner:          ctx.Runner,
		Out:             ctx.Out,
		Err:             ctx.Err,
		Home:            home,
		URL:             os.Getenv("DEVZONE_OLLAMA_URL"),
		Registry:        os.Getenv("DEVZONE_OLLAMA_REGISTRY"),
		Measures:        os.Getenv("DEVZONE_AI_MEASURES"),
		HostModel:       os.Getenv("DEVZONE_HOST_MODEL"),
		DevcontainerDir: codeRoot(),
		StateFile:       os.Getenv("DEVZONE_STATE"),
	}
}

// first returns the first argument or an empty string.
func first(args []string) string {
	if len(args) == 0 {
		return ""
	}
	return args[0]
}
