package guard

import "unicode"

// subshells extracts the bodies of backtick and $() substitutions, including
// those nested inside double quotes, so the refusal test can inspect them.
func subshells(s string) []string {
	var out []string
	i, n := 0, len(s)
	var quote byte
	for i < n {
		c := s[i]
		if quote == '\'' {
			if c == '\'' {
				quote = 0
			}
			i++
			continue
		}
		if quote == '"' {
			if c == '\\' {
				i += 2
				continue
			}
			if c == '"' {
				quote = 0
				i++
				continue
			}
			if c == '`' {
				j := i + 1
				for j < n && s[j] != '`' {
					j++
				}
				out = append(out, s[i+1:j])
				i = j + 1
				continue
			}
			if !(c == '$' && i+1 < n && s[i+1] == '(') {
				i++
				continue
			}
		}
		if c == '\\' && quote != '\'' {
			i += 2
			continue
		}
		if c == '\'' && quote == 0 {
			quote = '\''
			i++
			continue
		}
		if c == '"' && quote == 0 {
			quote = '"'
			i++
			continue
		}
		if c == '`' && quote != '\'' {
			j := i + 1
			for j < n && s[j] != '`' {
				j++
			}
			out = append(out, s[i+1:j])
			i = j + 1
			continue
		}
		if c == '$' && i+1 < n && s[i+1] == '(' && quote != '\'' {
			body, next := substitution(s, i)
			out = append(out, body)
			i = next
			continue
		}
		if quote == '"' {
			i++
			continue
		}
		i++
	}
	return out
}

// substitution reads one $() body with its nested quotes and parentheses.
func substitution(s string, i int) (string, int) {
	j, depth := i+2, 1
	var quote byte
	for j < len(s) && depth > 0 {
		ch := s[j]
		if quote != 0 {
			if quote == '\'' {
				if ch == '\'' {
					quote = 0
				}
			} else if quote == '"' {
				if ch == '\\' {
					j += 2
					continue
				}
				if ch == '"' {
					quote = 0
				}
			}
			j++
			continue
		}
		if ch == '\\' {
			j += 2
			continue
		}
		if ch == '\'' || ch == '"' {
			quote = ch
			j++
			continue
		}
		if ch == '$' && j+1 < len(s) && s[j+1] == '(' {
			depth++
			j += 2
			continue
		}
		if ch == '(' {
			depth++
		}
		if ch == ')' {
			depth--
		}
		j++
	}
	if j <= i+2 {
		return "", j
	}
	return s[i+2 : j-1], j
}

// isShellSpace reports whether r is whitespace in a -c argument.
func isShellSpace(r rune) bool { return unicode.IsSpace(r) }

// cArgs extracts the quoted arguments of -c options, which are inspected as
// commands in their own right by the guard.
func cArgs(s string) []string {
	var out []string
	i := 0
	for i < len(s) {
		if (i == 0 || isShellSpace(rune(s[i-1]))) && i+1 < len(s) && s[i] == '-' && s[i+1] == 'c' {
			j := i + 2
			if j < len(s) && isShellSpace(rune(s[j])) {
				for j < len(s) && isShellSpace(rune(s[j])) {
					j++
				}
				if j < len(s) && (s[j] == '\'' || s[j] == '"') {
					quote := s[j]
					j++
					k := j
					for k < len(s) && s[k] != quote {
						k++
					}
					if k < len(s) {
						out = append(out, s[j:k])
						i = k + 1
						continue
					}
				}
			}
		}
		i++
	}
	return out
}
