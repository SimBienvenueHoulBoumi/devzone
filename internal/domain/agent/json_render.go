package agent

import (
	"bytes"
	"fmt"
)

// Compact renders jq -c output (no spaces).
func (v JVal) Compact() string {
	var buf bytes.Buffer
	v.write(&buf, false)
	return buf.String()
}

// Pretty renders jq default (two-space indent).
func (v JVal) Pretty() string {
	var buf bytes.Buffer
	v.write(&buf, true)
	buf.WriteByte('\n')
	return buf.String()
}

func (v JVal) write(buf *bytes.Buffer, pretty bool) {
	switch v.kind {
	case jNull:
		buf.WriteString("null")
	case jBool:
		if v.b {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case jNum:
		buf.WriteString(v.num)
	case jStr:
		writeJSONString(buf, v.str)
	case jArr:
		v.writeArr(buf, pretty, 0)
	default:
		v.writeObj(buf, pretty, 0)
	}
}

func (v JVal) writeArr(buf *bytes.Buffer, pretty bool, depth int) {
	buf.WriteByte('[')
	for i, item := range v.arr {
		if i > 0 {
			buf.WriteByte(',')
		}
		if pretty {
			buf.WriteByte('\n')
			indent(buf, depth+1)
		}
		if pretty {
			item.writePretty(buf, depth+1)
		} else {
			item.write(buf, false)
		}
	}
	if pretty && len(v.arr) > 0 {
		buf.WriteByte('\n')
		indent(buf, depth)
	}
	buf.WriteByte(']')
}

func (v JVal) writeObj(buf *bytes.Buffer, pretty bool, depth int) {
	buf.WriteByte('{')
	for i, m := range v.obj {
		if i > 0 {
			buf.WriteByte(',')
		}
		if pretty {
			buf.WriteByte('\n')
			indent(buf, depth+1)
		}
		writeJSONString(buf, m.Key)
		buf.WriteByte(':')
		if pretty {
			buf.WriteByte(' ')
			m.Value.writePretty(buf, depth+1)
		} else {
			m.Value.write(buf, false)
		}
	}
	if pretty && len(v.obj) > 0 {
		buf.WriteByte('\n')
		indent(buf, depth)
	}
	buf.WriteByte('}')
}

func (v JVal) writePretty(buf *bytes.Buffer, depth int) {
	switch v.kind {
	case jArr:
		v.writeArr(buf, true, depth)
	case jObj:
		v.writeObj(buf, true, depth)
	default:
		v.write(buf, false)
	}
}

func indent(buf *bytes.Buffer, depth int) {
	for i := 0; i < depth; i++ {
		buf.WriteString("  ")
	}
}

func writeJSONString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			buf.WriteString("\\\"")
		case '\\':
			buf.WriteString("\\\\")
		case '\n':
			buf.WriteString("\\n")
		case '\r':
			buf.WriteString("\\r")
		case '\t':
			buf.WriteString("\\t")
		case '\b':
			buf.WriteString("\\b")
		case '\f':
			buf.WriteString("\\f")
		default:
			if r < 0x20 {
				fmt.Fprintf(buf, "\\u%04x", r)
			} else {
				buf.WriteRune(r)
			}
		}
	}
	buf.WriteByte('"')
}
