package command

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// confirmUninstall asks before anything is removed. --yes, or CONFIRM=yes, skips
// the question. Without a terminal the command refuses, so a script never removes
// anything by accident. proceed is false when the removal must not run; code is
// then the exit status of the command.
func confirmUninstall(ctx *cli.Context, yes bool) (proceed bool, code int) {
	if yes || confirmedByEnv() {
		return true, 0
	}
	if !isTerminal(ctx.Stdin) {
		fmt.Fprintln(ctx.Err, "✖ Cannot confirm without a terminal: CONFIRM=yes make desinstaller")
		return false, 1
	}
	fmt.Fprint(ctx.Out, "Permanently remove? Type yes: ")
	answer, _ := bufio.NewReader(ctx.Stdin).ReadString('\n')
	if strings.TrimSpace(answer) != "yes" {
		fmt.Fprintln(ctx.Out, "Canceled: nothing was removed.")
		return false, 0
	}
	return true, 0
}

// isTerminal reports whether r is a character device, a terminal for the user.
func isTerminal(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}
