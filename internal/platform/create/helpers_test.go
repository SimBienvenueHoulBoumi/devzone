package create

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// readyRunner programs a reachable devzone cluster for kubectl and a gh that
// is not connected; nothing else is programmed.
func readyRunner() *fake.Runner {
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, fexec.Result{})
	return r
}

// fakeLookPath finds kubectl and helm only, so no real PATH is consulted.
func fakeLookPath(name string) (string, error) {
	if name == "kubectl" || name == "helm" || name == "gh" {
		return name, nil
	}
	return "", os.ErrNotExist
}

// fakePackage builds a minimal package folder with the copied items.
func fakePackage(t *testing.T) string {
	t.Helper()
	pkg := t.TempDir()
	for _, dir := range []string{".devcontainer", "manage/scripts"} {
		if err := os.MkdirAll(filepath.Join(pkg, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		".devcontainer/devzone":       "#!/usr/bin/env bash\n",
		"manage/scripts/uninstall.sh": "#!/usr/bin/env bash\n",
		"Makefile":                    "all:\n",
		".gitattributes":              "*.sh text eol=lf\n",
		"README.md":                   "# readme\n",
		"LICENSE":                     "licence\n",
		"package.json":                `{"name":"devzone","version":"9.9.9"}` + "\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(pkg, filepath.FromSlash(name)), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return pkg
}

// createOptions builds hermetic options around a temp package and target,
// returning the target and the captured stdout/stderr buffers.
func createOptions(t *testing.T, runner fexec.Runner) (Options, string, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	target := filepath.Join(t.TempDir(), "mon")
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	return Options{
		Target:   target,
		Gitops:   "none",
		Package:  fakePackage(t),
		Version:  "9.9.9",
		In:       strings.NewReader(""),
		Out:      out,
		Err:      errOut,
		Runner:   runner,
		LookPath: fakeLookPath,
	}, target, out, errOut
}
