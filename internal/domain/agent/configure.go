package agent

import (
	"fmt"
	"os"
	"strings"
)

// permission keys always added to bash (protect ~/bash32, #210; git commit).
var bashAlways = []JMember{
	{Key: "git commit*", Value: JStr("allow")},
	{Key: "ln *bash32*", Value: JStr("deny")},
	{Key: "cp *bash32*", Value: JStr("deny")},
	{Key: "mv *bash32*", Value: JStr("deny")},
	{Key: "rm *bash32*", Value: JStr("deny")},
	{Key: "chmod *bash32*", Value: JStr("deny")},
	{Key: "install *bash32*", Value: JStr("deny")},
}

// RightsEditDeny turns permission.edit into an object and adds, last, one deny
// per rights file (#361); last matching rule wins so caller can't remove it.
func RightsEditDeny(config JVal) JVal {
	var patterns []string
	for _, f := range RightsFiles {
		patterns = append(patterns, f, "**/"+f)
	}
	perm0 := config.Get("permission")
	e := perm0.Get("edit")
	// jq (.permission.edit // "allow"): null or false -> "allow"
	if e.IsNull() || (e.Kind() == "boolean" && !e.Bool()) || !perm0.Has("edit") {
		e = JStr("allow")
	}
	var o JVal
	if e.Kind() == "object" {
		o = e
	} else {
		o = JObject(JMember{Key: "*", Value: e})
	}
	for _, k := range patterns {
		o.Del(k)
	}
	for _, k := range patterns {
		o.Set(k, JStr("deny"))
	}
	out := config
	perm := out.Get("permission")
	if perm.Kind() != "object" {
		perm = JObj()
	}
	perm.Set("edit", o)
	out.Set("permission", perm)
	return out
}

// Configure builds safe OPENCODE_CONFIG_CONTENT (#361): agent.json by default,
// completed by OPENCODE_CONFIG_CONTENT, deny entries kept last, bash32
// protected, git push denied. Returns compact JSON or an error.
func Configure(devcontainerDir string, envConfig string) (string, error) {
	defPath := devcontainerDir + string(os.PathSeparator) + "opencode" + string(os.PathSeparator) + "agent.json"
	defData, err := os.ReadFile(defPath)
	if err != nil {
		return "", fmt.Errorf("default configuration missing: %s", defPath)
	}
	def, err := ParseJSON(defData)
	if err != nil {
		return "", fmt.Errorf("opencode configuration unreadable: nothing launched")
	}
	var config JVal
	if envConfig != "" {
		env, err := ParseJSON([]byte(envConfig))
		if err != nil {
			return "", fmt.Errorf("opencode configuration unreadable: nothing launched")
		}
		config = mergeConfig(def, env)
	} else {
		config = def
	}
	// .permission.bash += always
	perm := config.Get("permission")
	if perm.Kind() != "object" {
		perm = JObj()
	}
	bash := perm.Get("bash")
	if bash.Kind() != "object" {
		bash = JObj()
	}
	for _, m := range bashAlways {
		bash.Set(m.Key, m.Value)
	}
	perm.Set("bash", bash)
	config.Set("permission", perm)
	config = RightsEditDeny(config)
	out := config.Compact()
	if !strings.Contains(out, `"git push*":"deny"`) {
		return "", fmt.Errorf("git push not denied: nothing launched")
	}
	return out, nil
}

// mergeConfig implements jq `$def * $env` + bash deny kept last (#361):
// recursive merge, devzone deny keys removed from merge then re-added at end.
func mergeConfig(def, env JVal) JVal {
	bashDef := def.Get("permission").Get("bash")
	bashEnv := env.Get("permission").Get("bash")
	if bashDef.Kind() != "object" {
		bashDef = JObj()
	}
	if bashEnv.Kind() != "object" {
		bashEnv = JObj()
	}
	var deny []string
	for _, m := range bashDef.obj {
		if m.Value.Kind() == "string" && m.Value.Str() == "deny" {
			deny = append(deny, m.Key)
		}
	}
	merged := JMerge(def, env)
	perm := merged.Get("permission")
	if perm.Kind() != "object" {
		perm = JObj()
	}
	// bash = (bashdef + bashenv) then remove deny keys
	bash := JPlus(bashDef, bashEnv)
	for _, k := range deny {
		bash.Del(k)
	}
	// re-add deny last
	for _, k := range deny {
		bash.Set(k, JStr("deny"))
	}
	perm.Set("bash", bash)
	merged.Set("permission", perm)
	return merged
}
