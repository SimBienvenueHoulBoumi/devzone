package agent

import (
	"fmt"
	"strings"
)

// ParseJSON parses JSON into a JVal, preserving object key order. It rejects
// trailing data and invalid syntax like jq. JSONC comments are not accepted
// (agent.json holds plain JSON); a caller strips comments first if needed.
func ParseJSON(data []byte) (JVal, error) {
	p := &jsonParser{s: string(data)}
	p.skipWS()
	v, err := p.value()
	if err != nil {
		return JNull(), err
	}
	p.skipWS()
	if p.i < len(p.s) {
		return JNull(), fmt.Errorf("trailing data at offset %d", p.i)
	}
	return v, nil
}

type jsonParser struct {
	s string
	i int
}

func (p *jsonParser) skipWS() {
	for p.i < len(p.s) {
		c := p.s[p.i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			p.i++
		} else {
			break
		}
	}
}

func (p *jsonParser) value() (JVal, error) {
	if p.i >= len(p.s) {
		return JNull(), fmt.Errorf("unexpected end of input")
	}
	c := p.s[p.i]
	switch {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		s, err := p.str()
		return JStr(s), err
	case c == 't':
		return p.lit("true", JBool(true))
	case c == 'f':
		return p.lit("false", JBool(false))
	case c == 'n':
		return p.lit("null", JNull())
	default:
		return p.number()
	}
}

func (p *jsonParser) lit(word string, v JVal) (JVal, error) {
	if strings.HasPrefix(p.s[p.i:], word) {
		p.i += len(word)
		return v, nil
	}
	return JNull(), fmt.Errorf("invalid literal at offset %d", p.i)
}

func (p *jsonParser) number() (JVal, error) {
	start := p.i
	if p.i < len(p.s) && p.s[p.i] == '-' {
		p.i++
	}
	for p.i < len(p.s) && isDigit(p.s[p.i]) {
		p.i++
	}
	if p.i < len(p.s) && p.s[p.i] == '.' {
		p.i++
		for p.i < len(p.s) && isDigit(p.s[p.i]) {
			p.i++
		}
	}
	if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
		p.i++
		if p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') {
			p.i++
		}
		for p.i < len(p.s) && isDigit(p.s[p.i]) {
			p.i++
		}
	}
	if p.i == start {
		return JNull(), fmt.Errorf("invalid value at offset %d", start)
	}
	return JNum(p.s[start:p.i]), nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func (p *jsonParser) object() (JVal, error) {
	p.i++
	out := JObj()
	p.skipWS()
	if p.i < len(p.s) && p.s[p.i] == '}' {
		p.i++
		return out, nil
	}
	for {
		p.skipWS()
		if p.i >= len(p.s) || p.s[p.i] != '"' {
			return JNull(), fmt.Errorf("expected object key at offset %d", p.i)
		}
		key, err := p.str()
		if err != nil {
			return JNull(), err
		}
		p.skipWS()
		if p.i >= len(p.s) || p.s[p.i] != ':' {
			return JNull(), fmt.Errorf("expected ':' at offset %d", p.i)
		}
		p.i++
		p.skipWS()
		val, err := p.value()
		if err != nil {
			return JNull(), err
		}
		out.Set(key, val)
		p.skipWS()
		if p.i < len(p.s) && p.s[p.i] == ',' {
			p.i++
			continue
		}
		if p.i < len(p.s) && p.s[p.i] == '}' {
			p.i++
			return out, nil
		}
		return JNull(), fmt.Errorf("expected ',' or '}' at offset %d", p.i)
	}
}

func (p *jsonParser) array() (JVal, error) {
	p.i++
	out := JArr()
	p.skipWS()
	if p.i < len(p.s) && p.s[p.i] == ']' {
		p.i++
		return out, nil
	}
	for {
		p.skipWS()
		val, err := p.value()
		if err != nil {
			return JNull(), err
		}
		out.arr = append(out.arr, val)
		p.skipWS()
		if p.i < len(p.s) && p.s[p.i] == ',' {
			p.i++
			continue
		}
		if p.i < len(p.s) && p.s[p.i] == ']' {
			p.i++
			return out, nil
		}
		return JNull(), fmt.Errorf("expected ',' or ']' at offset %d", p.i)
	}
}
