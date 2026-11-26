package agent

import (
	"fmt"
	"strings"
)

func (p *jsonParser) str() (string, error) {
	p.i++
	var b strings.Builder
	for p.i < len(p.s) {
		c := p.s[p.i]
		if c == '"' {
			p.i++
			return b.String(), nil
		}
		if c == '\\' {
			p.i++
			if p.i >= len(p.s) {
				break
			}
			e := p.s[p.i]
			switch e {
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			case '/':
				b.WriteByte('/')
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				if err := p.unicode(&b); err != nil {
					return "", err
				}
				continue
			default:
				return "", fmt.Errorf("invalid escape at offset %d", p.i)
			}
			p.i++
			continue
		}
		b.WriteByte(c)
		p.i++
	}
	return "", fmt.Errorf("unterminated string")
}

func (p *jsonParser) unicode(b *strings.Builder) error {
	if p.i+4 >= len(p.s) {
		return fmt.Errorf("short \\u escape")
	}
	hi := p.s[p.i+1 : p.i+5]
	n, err := parseHex4(hi)
	if err != nil {
		return err
	}
	p.i += 5
	r := rune(n)
	if r >= 0xD800 && r <= 0xDBFF && strings.HasPrefix(p.s[p.i:], "\\u") && p.i+6 <= len(p.s) {
		if lo, err2 := parseHex4(p.s[p.i+2 : p.i+6]); err2 == nil && lo >= 0xDC00 && lo <= 0xDFFF {
			r = 0x10000 + (r-0xD800)*0x400 + (rune(lo) - 0xDC00)
			p.i += 6
		}
	}
	b.WriteRune(r)
	return nil
}

func parseHex4(s string) (int, error) {
	n := 0
	for i := 0; i < 4; i++ {
		c := s[i]
		n <<= 4
		switch {
		case c >= '0' && c <= '9':
			n += int(c - '0')
		case c >= 'a' && c <= 'f':
			n += int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			n += int(c-'A') + 10
		default:
			return 0, fmt.Errorf("invalid \\u escape")
		}
	}
	return n, nil
}
