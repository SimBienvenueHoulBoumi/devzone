package agent

import (
	"sort"
	"strconv"
)

// JVal is a JSON value with insertion-ordered object keys, so output matches
// jq -c of the shell port exactly (jq preserves key order).
type JVal struct {
	kind   jKind
	str    string
	num    string
	b      bool
	arr    []JVal
	obj    []JMember
	scalar bool
}

// JMember is one object member, in insertion order.
type JMember struct {
	Key   string
	Value JVal
}

type jKind int

const (
	jNull jKind = iota
	jBool
	jNum
	jStr
	jArr
	jObj
)

// JNull returns JSON null.
func JNull() JVal { return JVal{kind: jNull} }

// JBool returns a JSON boolean.
func JBool(b bool) JVal { return JVal{kind: jBool, b: b} }

// JNum returns a JSON number from a literal (kept verbatim when valid).
func JNum(lit string) JVal { return JVal{kind: jNum, num: lit} }

// JInt returns a JSON number from an integer.
func JInt(n int) JVal { return JVal{kind: jNum, num: strconv.Itoa(n)} }

// JStr returns a JSON string.
func JStr(s string) JVal { return JVal{kind: jStr, str: s} }

// JArr returns a JSON array.
func JArr(items ...JVal) JVal { return JVal{kind: jArr, arr: items} }

// JObj returns an empty JSON object.
func JObj() JVal { return JVal{kind: jObj} }

// JObject builds a JSON object from ordered members.
func JObject(members ...JMember) JVal { return JVal{kind: jObj, obj: members} }

// Kind returns the JSON kind name.
func (v JVal) Kind() string {
	switch v.kind {
	case jNull:
		return "null"
	case jBool:
		return "boolean"
	case jNum:
		return "number"
	case jStr:
		return "string"
	case jArr:
		return "array"
	default:
		return "object"
	}
}

// IsNull reports whether v is null.
func (v JVal) IsNull() bool { return v.kind == jNull }

// Bool returns the boolean value (false when not a boolean).
func (v JVal) Bool() bool { return v.kind == jBool && v.b }

// Str returns the string value (empty when not a string).
func (v JVal) Str() string { return v.str }

// Arr returns the array items (nil when not an array).
func (v JVal) Arr() []JVal { return v.arr }

// Obj returns ordered members (nil when not an object).
func (v JVal) Obj() []JMember { return v.obj }

// Get returns member key of an object, or null.
func (v JVal) Get(key string) JVal {
	if v.kind != jObj {
		return JNull()
	}
	for _, m := range v.obj {
		if m.Key == key {
			return m.Value
		}
	}
	return JNull()
}

// Has reports whether an object has key.
func (v JVal) Has(key string) bool {
	if v.kind != jObj {
		return false
	}
	for _, m := range v.obj {
		if m.Key == key {
			return true
		}
	}
	return false
}

// Keys returns ordered object keys.
func (v JVal) Keys() []string {
	keys := make([]string, 0, len(v.obj))
	for _, m := range v.obj {
		keys = append(keys, m.Key)
	}
	return keys
}

// Set sets member key, replacing in place or appending at the end (jq + order).
func (v *JVal) Set(key string, val JVal) {
	if v.kind != jObj {
		*v = JObj()
	}
	for i := range v.obj {
		if v.obj[i].Key == key {
			v.obj[i].Value = val
			return
		}
	}
	v.obj = append(v.obj, JMember{Key: key, Value: val})
}

// Del removes member key (no-op when absent).
func (v *JVal) Del(key string) {
	for i := range v.obj {
		if v.obj[i].Key == key {
			v.obj = append(v.obj[:i], v.obj[i+1:]...)
			return
		}
	}
}

// JMerge implements jq `*`: recursive object merge, b wins, order kept.
func JMerge(a, b JVal) JVal {
	if a.kind != jObj || b.kind != jObj {
		return b
	}
	out := a
	keys := append([]string{}, out.Keys()...)
	for _, k := range keys {
		if !b.Has(k) {
			continue
		}
		merged := JMerge(out.Get(k), b.Get(k))
		out.Set(k, merged)
	}
	for _, m := range b.obj {
		if !a.Has(m.Key) {
			out.Set(m.Key, m.Value)
		}
	}
	return out
}

// JPlus implements jq `+` on objects: b members appended/overwritten, order kept.
func JPlus(a, b JVal) JVal {
	out := a
	if out.kind != jObj {
		out = JObj()
	}
	for _, m := range b.obj {
		out.Set(m.Key, m.Value)
	}
	return out
}

// sortedStrings returns a sorted copy.
func sortedStrings(in []string) []string {
	out := append([]string{}, in...)
	sort.Strings(out)
	return out
}
