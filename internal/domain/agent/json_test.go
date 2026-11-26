package agent

import "testing"

func TestParseJSONOrder(t *testing.T) {
	v, err := ParseJSON([]byte(`{"b":1,"a":{"x":2,"y":3},"c":[4,5],"s":"hello\n"}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := v.Compact(); got != `{"b":1,"a":{"x":2,"y":3},"c":[4,5],"s":"hello\n"}` {
		t.Fatal("order/roundtrip", got)
	}
	if v.Get("a").Get("y").num != "3" {
		t.Fatal("number")
	}
	if v.Get("c").Arr()[1].Kind() != "number" {
		t.Fatal("array")
	}
}

func TestJMerge(t *testing.T) {
	a, _ := ParseJSON([]byte(`{"permission":{"bash":{"*":"ask","x":"deny"}},"k":1}`))
	b, _ := ParseJSON([]byte(`{"permission":{"bash":{"*":"allow","y":"deny"}},"z":2}`))
	out := JMerge(a, b).Compact()
	if !containsStr(out, `"*":"allow"`) || !containsStr(out, `"x":"deny"`) || !containsStr(out, `"y":"deny"`) {
		t.Fatal("merge", out)
	}
	if !containsStr(out, `"k":1`) || !containsStr(out, `"z":2`) {
		t.Fatal("merge keys", out)
	}
}

func TestRightsEditDenyLast(t *testing.T) {
	c, _ := ParseJSON([]byte(`{"permission":{"edit":{"*":"allow",".repowarden.conf":"allow","src/*":"allow"},"bash":{}}}`))
	out := RightsEditDeny(c).Compact()
	if !containsStr(out, `".repowarden.conf":"deny"`) {
		t.Fatal("deny not set", out)
	}
	// deny keys last
	obj := RightsEditDeny(c).Get("permission").Get("edit").Obj()
	n := len(obj)
	if n < 8 {
		t.Fatal("not 8", out)
	}
	for i := n - 8; i < n; i++ {
		if obj[i].Value.Str() != "deny" {
			t.Fatal("deny not last", out)
		}
	}
	// ".repowarden.conf" no longer allow
	for _, m := range obj {
		if m.Key == ".repowarden.conf" && m.Value.Str() != "deny" {
			t.Fatal("allow kept")
		}
	}
}

func containsStr(s, sub string) bool { return len(s) >= len(sub) && indexOf(s, sub) >= 0 }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
