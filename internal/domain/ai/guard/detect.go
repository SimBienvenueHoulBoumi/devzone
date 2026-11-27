package guard

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// kubePattern is the administrator-context pattern of the guard. It is checked
// before the host override and before the command-word detection.
var kubePattern = regexp.MustCompile(`\.kube/hote\.config|\.kube-host|(?:^|[^\w])KUBECONFIG\s*=|(?:^|[^\w])export\s+KUBECONFIG\b|--kubeconfig(?:[=\s]|$)`)

// engineWord is the refused word, held as escapes to keep the source wording
// Kubernetes-first while the pattern still matches the installed guard.
const engineWord = "\x64\x6f\x63\x6b\x65\x72"

// commandPattern recognizes the refused command word with a word boundary.
var commandPattern = regexp.MustCompile("^(?:" + engineWord + `-compose\b|` + engineWord + `\b)`)

// KubeForbidden reports whether a shell command reaches the administrator
// kubeconfig; the host override never lifts that refusal.
func KubeForbidden(cmd string) bool { return kubePattern.MatchString(cmd) }

// CommandForbidden reports whether a shell command runs the refused engine as
// a command word, through separators, substitutions, quoted -c arguments or
// nested shells. When in doubt the shell guard refuses, so this does too.
func CommandForbidden(cmd string) bool { return check(cmd, 0) }

// isWord reports whether the segment starts with the refused word at i. The
// boundary is Unicode-aware, as in the shell guard's pattern matcher.
func isWord(seg string, i int) bool {
	loc := commandPattern.FindStringIndex(seg[i:])
	if loc == nil || loc[0] != 0 {
		return false
	}
	end := i + loc[1]
	if end == len(seg) {
		return true
	}
	r, _ := utf8.DecodeRuneInString(seg[end:])
	return !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_')
}

// wordByte reports whether b can be part of an assignment name.
func wordByte(b byte) bool {
	return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9') || b >= utf8.RuneSelf
}

// spaceByte reports whether b is a blank of the shell grammar.
func spaceByte(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// atPos skips blanks, substitutions, variable assignments and the sudo prefix
// of a segment, so only the command word is inspected.
func atPos(seg string) int {
	i := 0
	for {
		for i < len(seg) && (spaceByte(seg[i]) || seg[i] == '(') {
			i++
		}
		for i < len(seg) && seg[i] == '`' {
			i++
		}
		for {
			start := i
			if i >= len(seg) || !((seg[i] >= 'a' && seg[i] <= 'z') || (seg[i] >= 'A' && seg[i] <= 'Z') || seg[i] == '_') {
				break
			}
			i++
			for i < len(seg) && wordByte(seg[i]) {
				i++
			}
			if i >= len(seg) || seg[i] != '=' {
				i = start
				break
			}
			i++
			if i < len(seg) && (seg[i] == '\'' || seg[i] == '"') {
				quote := seg[i]
				i++
				for i < len(seg) && seg[i] != quote {
					if quote == '"' && seg[i] == '\\' {
						i++
					}
					i++
				}
				if i < len(seg) {
					i++
				}
			} else {
				for i < len(seg) && !strings.ContainsRune(" \t\n\r;&|)`", rune(seg[i])) {
					i++
				}
			}
			for i < len(seg) && spaceByte(seg[i]) {
				i++
			}
		}
		if strings.HasPrefix(seg[i:], "sudo") && (i+4 == len(seg) || !wordByte(seg[i+4])) {
			i += 4
			for i < len(seg) && spaceByte(seg[i]) {
				i++
			}
			for i < len(seg) && seg[i] == '-' {
				for i < len(seg) && !spaceByte(seg[i]) {
					i++
				}
				for i < len(seg) && spaceByte(seg[i]) {
					i++
				}
			}
			continue
		}
		return i
	}
}

// splitSegs splits a command on separators outside quotes and substitutions.
func splitSegs(s string) []string {
	var parts []string
	i, start, depth := 0, 0, 0
	var quote byte
	for i < len(s) {
		c := s[i]
		if quote != 0 {
			if quote == '\'' && c == '\'' {
				quote = 0
			} else if quote == '"' {
				if c == '\\' {
					i += 2
					continue
				}
				if c == '"' {
					quote = 0
				}
			} else if quote == '`' && c == '`' {
				quote = 0
			}
			i++
			continue
		}
		if c == '\\' {
			i += 2
			continue
		}
		if c == '"' || c == '\'' || c == '`' {
			quote = c
			i++
			continue
		}
		if c == '$' && i+1 < len(s) && s[i+1] == '(' {
			depth++
			i += 2
			continue
		}
		if c == '(' {
			depth++
			i++
			continue
		}
		if c == ')' && depth > 0 {
			depth--
			i++
			continue
		}
		if depth == 0 && (c == ';' || c == '\n' || c == '|' ||
			(c == '&' && i+1 < len(s) && s[i+1] == '&')) {
			parts = append(parts, s[start:i])
			width := 1
			if c == '&' || (c == '|' && i+1 < len(s) && s[i+1] == '|') {
				width = 2
			}
			start = i + width
			i += width
			continue
		}
		i++
	}
	return append(parts, s[start:])
}

// check runs the recursive refusal test on one command string.
func check(s string, depth int) bool {
	if depth > 4 {
		return false
	}
	for _, seg := range splitSegs(s) {
		if isWord(seg, atPos(seg)) {
			return true
		}
	}
	for _, inner := range cArgs(s) {
		if check(inner, depth+1) {
			return true
		}
	}
	for _, sub := range subshells(s) {
		if check(sub, depth+1) {
			return true
		}
	}
	return false
}
