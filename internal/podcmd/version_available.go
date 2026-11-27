package podcmd

import (
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// versionAvailableLine prints the "newer devzone available" line when the
// published version is newer than the folder version, and stays silent
// otherwise; it never fails, like the shell version_available_line.
func versionAvailableLine(ctx *cli.Context) int {
	root := devzoneRoot()
	folder, err := folderVersion(root)
	if err != nil {
		return 0
	}
	d := jsonDeps{ctx: ctx, root: root, code: codeRoot()}
	published := strings.TrimPrefix(publishedVersion(d), "v")
	if published == "" {
		return 0
	}
	if versionIsNewer(published, folder) {
		fmt.Fprintf(ctx.Out, "  ○ devzone %s available: on the workstation, devzone update\n", published)
	}
	return 0
}

// versionIsNewer reports whether version a is newer than version b, comparing
// dotted numeric components and treating missing components as 0, like the
// shell awk version that split on "." and added +0.
func versionIsNewer(a, b string) bool {
	x := strings.Split(a, ".")
	y := strings.Split(b, ".")
	n := len(x)
	if len(y) > n {
		n = len(y)
	}
	for i := 0; i < n; i++ {
		var p, q int
		if i < len(x) {
			p = awkNumber(x[i])
		}
		if i < len(y) {
			q = awkNumber(y[i])
		}
		if p > q {
			return true
		}
		if p < q {
			return false
		}
	}
	return false
}

// awkNumber reads the leading integer of s like awk's +0 conversion: leading
// whitespace is skipped, a sign is honored, parsing stops at the first
// non-digit, and anything without digits is 0.
func awkNumber(s string) int {
	s = strings.TrimLeft(s, " \t\n\r\f\v")
	neg := false
	if strings.HasPrefix(s, "+") {
		s = s[1:]
	} else if strings.HasPrefix(s, "-") {
		neg = true
		s = s[1:]
	}
	n := 0
	seen := false
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
		seen = true
	}
	if !seen {
		return 0
	}
	if neg {
		return -n
	}
	return n
}
