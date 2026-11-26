package podcmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// portsJSON runs the Go port list command and keeps its JSON key order.
func portsJSON(d jsonDeps, errs jsonObject) (any, jsonObject) {
	out, code, err := d.run("devzone", "port", "list", "--json")
	if err != nil || code != 0 {
		errs.set("ports", "port unavailable")
		return nil, errs
	}
	if !jqTrueJSON(out) {
		errs.set("ports", "ports output unreadable")
		return nil, errs
	}
	return rawJSON([]byte(out)), errs
}

// applicationsJSON runs the catalog JSON command and falls back to an empty list.
func applicationsJSON(d jsonDeps, errs jsonObject) (any, jsonObject) {
	script := filepath.Join(d.code, "catalog.sh")
	out, code, err := d.run("bash", script, "json")
	if err != nil || code != 0 {
		out = "[]"
	}
	if !jqTrueJSON(out) {
		out = "[]"
		errs.set("modules", "catalog.sh json unavailable")
	}
	return rawJSON([]byte(out)), errs
}

// jqTrueJSON reports whether a document is valid and truthy for jq -e, which
// rejects only the false and null values.
func jqTrueJSON(doc string) bool {
	trimmed := strings.TrimSpace(doc)
	if !json.Valid([]byte(trimmed)) {
		return false
	}
	return trimmed != "null" && trimmed != "false"
}

// stateFileExists reports whether the given disposable state file is present.
func stateFileExists(d jsonDeps) bool {
	_, err := os.Stat(d.st.Path())
	return err == nil
}
