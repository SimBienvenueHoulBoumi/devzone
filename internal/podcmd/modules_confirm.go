package podcmd

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

// confirmRemoval asks before a removal that deletes data (confirm_removal). It
// reports whether the change goes on; a refusal of postgres cancels it, mysql
// and gitlab still disable (the data is kept). The answer is read from stdin.
func (m *modules) confirmRemoval(app string, extra []string) bool {
	m.deleteData = false
	if m.value(app) != "on" {
		return true
	}
	for _, arg := range extra {
		if arg == "--yes" {
			m.deleteData = true
		}
	}
	if m.deleteData || !m.interactive {
		return true
	}
	switch app {
	case "mysql":
		fmt.Fprint(m.ctx.Err, "Disabling mysql removes the server; the volume and databases stay. Also delete the devzone-mysql namespace and its volumes? [y/N] ")
	case "gitlab":
		fmt.Fprint(m.ctx.Err, "Disabling gitlab keeps the Rails secret (browser sessions stay valid at reinstall). Also delete the Rails secret? [y/N] ")
	default:
		fmt.Fprintf(m.ctx.Err, "Disabling %s deletes all its databases. Continue? [y/N] ", app)
	}
	answer := readLine(m.ctx.Stdin)
	switch answer {
	case "y", "Y", "yes":
		m.deleteData = true
		return true
	}
	switch app {
	case "mysql", "gitlab":
		return true
	}
	fmt.Fprintln(m.ctx.Out, "Aborted: nothing was deleted.")
	return false
}

// readLine reads one line of input like the shell `read -r`; empty on EOF.
func readLine(in io.Reader) string {
	if in == nil {
		return ""
	}
	line, _ := bufio.NewReader(in).ReadString('\n')
	return strings.TrimRight(line, "\r\n")
}
