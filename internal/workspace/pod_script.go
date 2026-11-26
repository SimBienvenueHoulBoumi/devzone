package workspace

import "strings"

// lfScript returns a script with LF line endings, ready for bash in the pod.
// bash reads a trailing CR as part of the command or its arguments, so a
// script checked out with CRLF on a Windows workstation would break there.
// The conversion happens at this boundary whatever the source of the script:
// a Go constant, a file embedded in the binary built on Windows, or a file
// read from a checkout made with core.autocrlf.
func lfScript(script string) string {
	withLF := strings.ReplaceAll(script, "\r\n", "\n")
	return strings.ReplaceAll(withLF, "\r", "\n")
}
