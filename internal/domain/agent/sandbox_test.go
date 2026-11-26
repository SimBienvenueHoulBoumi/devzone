package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sandbox builds an isolated environment with fake opencode/kubectl/curl/getent
// and a fake devzone is-enabled; returns funcs. No real cluster/network.
type sandbox struct {
	root  string
	home  string
	state string
	bin   string
	dc    string
	proj  string
	brief string
}

func newSandbox(t *testing.T) *sandbox {
	t.Helper()
	base := t.TempDir()
	s := &sandbox{
		root:  filepath.Join(base, "racine"),
		home:  filepath.Join(base, "home"),
		state: filepath.Join(base, "etat"),
		bin:   filepath.Join(base, "bin"),
		dc:    filepath.Join(base, "dc"),
	}
	s.proj = filepath.Join(s.root, "workspace", "projet")
	for _, d := range []string{s.root, s.home, s.bin, s.dc, s.proj, filepath.Join(s.root, "workspace")} {
		os.MkdirAll(d, 0o755)
	}
	// real agent.json
	repoDC := repoDevcontainer(t)
	os.MkdirAll(filepath.Join(s.dc, "opencode"), 0o755)
	copyFilePreserve(filepath.Join(repoDC, "opencode", "agent.json"), filepath.Join(s.dc, "opencode", "agent.json"))
	// fake devzone: is-enabled ai -> 0
	writeFileT(t, filepath.Join(s.dc, "devzone"), "#!/usr/bin/env bash\nif [ \"$1\" = is-enabled ] && [ \"$2\" = ai ]; then exit 0; fi\nexit 1\n")
	os.Chmod(filepath.Join(s.dc, "devzone"), 0o755)
	// fake opencode
	opencode := `#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
printf 'opencode/big-pickle\nopencode/deepseek-v4.1-flash-free\nopencode/hy4-flash-free\nopencode/nemotron-3.5-super-vl-free\nopencode/nemotron-3.5-lightning-free\nopencode/mimo-v2.6-flash-free\nopencode/beam-free\nopencode/flint-40b-free\nopencode/longcat-2.5-free\n'
exit 0
fi
modele=""
for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
if [ "$#" -gt 0 ]; then consigne="${!#}"; else consigne=""; fi
echo "$modele" >>"${FAKE_OP_LOG:?}"
printf '%s\n---\n' "$consigne" >>"${FAKE_OP_CONSIGNE_LOG:?}"
printf '%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >"${FAKE_OP_CONFIG_LOG:?}"
printf '%s\n' "${KUBECONFIG:-}" >"${FAKE_OP_KUBECONFIG_LOG:?}"
echo "session $modele: instruction read, work starting"
echo "the model $modele handled the instruction, the matching tests pass"
echo "end of session $modele: no error, no permission refusal"
exit 0
`
	writeFileT(t, filepath.Join(s.bin, "opencode"), opencode)
	os.Chmod(filepath.Join(s.bin, "opencode"), 0o755)
	// fake kubectl/curl/getent/gh
	for name, body := range map[string]string{
		"kubectl": "#!/usr/bin/env bash\nexit 1\n",
		"curl":    "#!/usr/bin/env bash\nexit 1\n",
		"getent":  "#!/usr/bin/env bash\nexit 1\n",
		"gh":      "#!/usr/bin/env bash\nexit 0\n",
	} {
		writeFileT(t, filepath.Join(s.bin, name), body)
		os.Chmod(filepath.Join(s.bin, name), 0o755)
	}
	// fake ps (no other sessions visible)
	writeFileT(t, filepath.Join(s.bin, "ps"), "#!/usr/bin/env bash\nexit 0\n")
	os.Chmod(filepath.Join(s.bin, "ps"), 0o755)
	// brief
	s.brief = filepath.Join(s.root, "workspace", "consigne.txt")
	writeFileT(t, s.brief, "construis la feature\n")
	// env
	t.Setenv("PATH", s.bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", s.home)
	t.Setenv("DEVZONE_ROOT", s.root)
	t.Setenv("DEVZONE_AGENT_STATE", s.state)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	t.Setenv("FAKE_OP_LOG", filepath.Join(base, "opencode.log"))
	t.Setenv("FAKE_OP_CONSIGNE_LOG", filepath.Join(base, "consignes.log"))
	t.Setenv("FAKE_OP_CONFIG_LOG", filepath.Join(base, "config.log"))
	t.Setenv("FAKE_OP_KUBECONFIG_LOG", filepath.Join(base, "kubeconfig.log"))
	os.WriteFile(os.Getenv("FAKE_OP_LOG"), nil, 0o644)
	os.WriteFile(os.Getenv("FAKE_OP_CONSIGNE_LOG"), nil, 0o644)
	return s
}

func repoDevcontainer(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "..", "..", ".devcontainer")
}

func (s *sandbox) opts() Options {
	return Options{
		Runner:          ExecRunner{},
		Clock:           RealClock{},
		Starter:         ExecSessionStarter{},
		DevcontainerDir: s.dc,
		Racine:          s.root,
		StateDir:        s.state,
		Home:            s.home,
	}
}

func (s *sandbox) journal() string {
	return filepath.Join(s.root, "workspace", ".agents", "projet.log")
}

func opLog() string { return readFileString(os.Getenv("FAKE_OP_LOG")) }

func modelsLaunched() []string {
	var out []string
	for _, l := range strings.Split(strings.TrimRight(opLog(), "\n"), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}
