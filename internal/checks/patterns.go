package checks

import (
	"path/filepath"
	"strings"
)

// accentLeads are the UTF-8 lead bytes of the accented letters of the former
// shell check; accentTails is its exact list of continuation bytes.
var accentLeads = map[byte]bool{0xc3: true, 0xc5: true}

var accentTails = map[byte]bool{
	0x80: true, 0x82: true, 0x84: true, 0x86: true, 0x87: true, 0x88: true,
	0x89: true, 0x8a: true, 0x8b: true, 0x8e: true, 0x8f: true, 0x92: true,
	0x93: true, 0x94: true, 0x96: true, 0x99: true, 0x9b: true, 0x9c: true,
	0xa0: true, 0xa2: true, 0xa4: true, 0xa6: true, 0xa7: true, 0xa8: true,
	0xa9: true, 0xaa: true, 0xab: true, 0xae: true, 0xaf: true, 0xb4: true,
	0xb6: true, 0xb8: true, 0xb9: true, 0xbb: true, 0xbc: true, 0xbf: true,
}

// hasAccent reproduces the byte pair matching of the former shell check.
func hasAccent(line []byte) bool {
	for i := 0; i+1 < len(line); i++ {
		if accentLeads[line[i]] && accentTails[line[i+1]] {
			return true
		}
	}
	return false
}

// hasFrenchWord reports whether a whole line holds an accented byte pair or a
// frequent French word as a whole word, case-insensitive.
func hasFrenchWord(line string) bool {
	return hasAccent([]byte(line)) || frequentPattern.MatchString(line)
}

// lineScanner keeps the shell case state over the lines of one file.
type lineScanner struct {
	inShellCase bool
}

// frenchTokens returns the French command words of a case pattern or of a
// devzone call on the line. Comments and test declarations hold no command.
func (s *lineScanner) frenchTokens(line string) []string {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "@test") {
		return nil
	}
	if strings.HasPrefix(trimmed, "case ") && strings.HasSuffix(trimmed, ":") {
		expression := strings.TrimSuffix(strings.TrimPrefix(trimmed, "case "), ":")
		if strings.ContainsAny(expression, "().[]{}") {
			return nil
		}
		return frenchIn(caseTokens(expression))
	}
	if s.inShellCase {
		if trimmed == "esac" {
			s.inShellCase = false
			return nil
		}
		if tokens, ok := shellPattern(trimmed); ok {
			return frenchIn(tokens)
		}
	}
	if strings.HasPrefix(trimmed, "case ") && strings.HasSuffix(trimmed, " in") {
		s.inShellCase = true
		return nil
	}
	return frenchIn(devzoneArguments(trimmed))
}

// frenchIn keeps the tokens that are French command words.
func frenchIn(tokens []string) []string {
	var out []string
	for _, token := range tokens {
		if commandSet[token] {
			out = append(out, token)
		}
	}
	return out
}

// caseTokens splits the expression of a Go case clause into plain tokens.
func caseTokens(expr string) []string {
	return strings.FieldsFunc(expr, func(r rune) bool {
		return !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') &&
			!(r >= '0' && r <= '9') && r != '-' && r != '_'
	})
}

// shellPattern extracts the tokens before the first ')' of a case pattern.
// A line that also holds '(', '=' or '&' is code, not a pattern.
func shellPattern(trimmed string) ([]string, bool) {
	index := strings.IndexByte(trimmed, ')')
	if index < 0 {
		return nil, false
	}
	prefix := trimmed[:index]
	if strings.ContainsAny(prefix, "(=&;{}`!") {
		return nil, false
	}
	tokens := strings.FieldsFunc(prefix, func(r rune) bool { return r == '|' || r == ' ' || r == '\t' || r == '\\' })
	for i, token := range tokens {
		tokens[i] = strings.Trim(token, `"'`)
	}
	return tokens, len(tokens) > 0
}

// devzoneArguments returns the words that follow a devzone command on a line.
func devzoneArguments(trimmed string) []string {
	fields := strings.Fields(trimmed)
	isCommand := func(field string) bool {
		return filepath.Base(strings.Trim(field, `"'()[];,`)) == "devzone"
	}
	index := -1
	if len(fields) > 0 && isCommand(fields[0]) {
		index = 0
	} else if len(fields) > 1 && (fields[0] == "bash" || fields[0] == "env" || fields[0] == "exec" || fields[0] == "command") && isCommand(fields[1]) {
		index = 1
	}
	if index < 0 {
		return nil
	}
	var words []string
	for _, next := range fields[index+1:] {
		switch next {
		case "|", "||", "&&", ";":
			return words
		}
		word := strings.Trim(next, `"'()[];,`)
		if word != "" && word != ":" {
			words = append(words, word)
		}
	}
	return words
}
