package podcmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// runAccount handles the limited account commands: token renews the token of
// the limited account, fresh reports whether it is fresh, any other argument is
// a usage error.
func runAccount(ctx *cli.Context) int {
	switch {
	case len(ctx.Args) == 1 && ctx.Args[0] == "token":
		return runAccountToken(ctx)
	case len(ctx.Args) == 1 && ctx.Args[0] == "fresh":
		return runAccountFresh(ctx)
	}
	errOut := ctx.Err
	if errOut == nil {
		errOut = io.Discard
	}
	fmt.Fprintln(errOut, "usage: devzone account token")
	fmt.Fprintln(errOut, "       devzone account fresh")
	return 2
}

// runAccountToken renews the token of the limited account: setup, catch-up of
// the existing devzone namespaces, token renewal and agent kubeconfig. Without
// a chosen services cluster, nothing runs (code 0).
func runAccountToken(ctx *cli.Context) int {
	contextName := accountContextName()
	if contextName == "" {
		return 0
	}
	api := kube.Kube{Runner: ctx.Runner}
	if err := api.Setup(context.Background(), contextName); err != nil {
		return accountFail(err, ctx.Err)
	}
	if err := api.CatchUp(context.Background(), contextName); err != nil {
		return accountFail(err, ctx.Err)
	}
	if err := api.Token(context.Background(), contextName); err != nil {
		return accountFail(err, ctx.Err)
	}
	if err := api.AgentConfig(context.Background()); err != nil {
		return accountFail(err, ctx.Err)
	}
	return 0
}

// accountFail writes the failure of the limited account and returns its code.
// Only the errors that the shell token cycle printed are shown: the other
// failures keep the silent behaviour of the shell original.
func accountFail(err error, errOut io.Writer) int {
	var message kube.MessageError
	if errors.As(err, &message) {
		if errOut == nil {
			errOut = io.Discard
		}
		fmt.Fprintf(errOut, "devzone : %s\n", message.Text)
	}
	return 1
}

// runAccountFresh reports whether the token of the limited account is fresh,
// without any network call and without printing anything.
func runAccountFresh(ctx *cli.Context) int {
	api := kube.Kube{}
	if api.TokenFresh() {
		return 0
	}
	return 1
}

// accountContextName returns the last chosen services cluster of the state,
// empty when none (the token renewal is then a no-op, as before the Go port).
// DEVZONE_STATE names the state file exactly, DEVZONE_ROOT its folder; without
// either, the folder comes from the pod shell entry point passed by the
// launcher.
func accountContextName() string {
	location := os.Getenv("DEVZONE_STATE")
	if location == "" {
		root := os.Getenv("DEVZONE_ROOT")
		if root == "" {
			script, err := podScript()
			if err != nil {
				return ""
			}
			root = filepath.Dir(filepath.Dir(script))
		}
		location = filepath.Join(root, ".devzone.modules")
	}
	data, err := os.ReadFile(location)
	if err != nil {
		return ""
	}
	name := ""
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "cluster=") {
			name = strings.TrimSuffix(strings.TrimPrefix(line, "cluster="), "\r")
		}
	}
	return name
}
