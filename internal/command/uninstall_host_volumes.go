package command

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// errReadDevcontainer means the devcontainer configuration could not be read
// through npx: the shell uninstaller stopped there, before removing anything.
var errReadDevcontainer = errors.New("cannot read .devcontainer/devcontainer.json (npx @devcontainers/cli)")

// sourcePattern extracts the volume name of a mount written "source=<name>,...".
var sourcePattern = regexp.MustCompile(`source=([^,]+)`)

// devcontainerVolumes returns the names of the volume mounts of the devcontainer
// configuration, as the devcontainer CLI resolves them (${localEnv:...} included,
// so the names carry the instance). A configuration that does not parse gives no
// volume, as the shell's node script did.
func devcontainerVolumes(ctx context.Context, runner exec.Runner, root string) ([]string, error) {
	res, err := runner.Run(ctx, "npx", []string{"-y", "@devcontainers/cli", "read-configuration", "--workspace-folder", root}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return nil, errReadDevcontainer
	}
	var doc struct {
		Configuration struct {
			Mounts []json.RawMessage `json:"mounts"`
		} `json:"configuration"`
	}
	if err := json.Unmarshal(res.Stdout, &doc); err != nil {
		return nil, nil
	}
	var names []string
	for _, raw := range doc.Configuration.Mounts {
		if name := volumeName(mountSpec(raw)); name != "" {
			names = append(names, name)
		}
	}
	return names, nil
}

// mountSpec returns a mount as "source=<s>,type=<t>" when it is an object, or the
// string itself. A missing field reads "undefined", as the template of the shell
// script did with JavaScript.
func mountSpec(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var obj struct {
		Source json.RawMessage `json:"source"`
		Type   json.RawMessage `json:"type"`
	}
	if json.Unmarshal(raw, &obj) != nil {
		return ""
	}
	return "source=" + textField(obj.Source) + ",type=" + textField(obj.Type)
}

// textField returns a JSON string as its text, "undefined" for anything else.
func textField(raw json.RawMessage) string {
	var s string
	if len(raw) > 0 && json.Unmarshal(raw, &s) == nil {
		return s
	}
	return "undefined"
}

// volumeName returns the source name of a volume mount, "" for another kind.
func volumeName(spec string) string {
	if !strings.Contains(spec, "type=volume") {
		return ""
	}
	m := sourcePattern.FindStringSubmatch(spec)
	if m == nil {
		return ""
	}
	return m[1]
}
