package workspace

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestArgocdWanted checks that argocd is wanted by default and that only the
// exact value off turns it away, with the last duplicate winning.
func TestArgocdWanted(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		content string
		want    bool
	}{
		{"missing file", false, "", true},
		{"key absent", true, "postgres=on\n", true},
		{"on", true, "argocd=on\n", true},
		{"off", true, "argocd=off\n", false},
		{"false is wanted", true, "argocd=false\n", true},
		{"Off is wanted", true, "argocd=Off\n", true},
		{"last duplicate is off", true, "argocd=on\nargocd=off\n", false},
		{"last duplicate is on", true, "argocd=off\nargocd=on\n", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			modules := filepath.Join(dir, modulesFile)
			if tc.present {
				writeStateFile(t, dir, tc.content)
			}
			if got := argocdWanted(modules); got != tc.want {
				t.Fatalf("argocdWanted = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestArgocdInstalled checks the success, the failure and the kubectl that
// cannot start, with the output and errors of kubectl ignored.
func TestArgocdInstalled(t *testing.T) {
	cases := []struct {
		name    string
		replies []reply
		want    bool
	}{
		{"success", []reply{
			{match: contextsCall, stdout: currentContext},
			{match: "get namespace devzone-argocd", status: 0},
		}, true},
		{"namespace absent", []reply{
			{match: contextsCall, stdout: currentContext},
			{match: "get namespace devzone-argocd", status: 1},
		}, false},
		{"kubectl cannot start", []reply{
			{match: contextsCall, stdout: currentContext},
			{match: "get namespace devzone-argocd", err: errors.New("exec: kubectl not found")},
		}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := &fakeRunner{replies: tc.replies}
			if got := argocdInstalled(r); got != tc.want {
				t.Fatalf("argocdInstalled = %v, want %v", got, tc.want)
			}
			wantCalls(t, r.calls, contextsCall, "get namespace devzone-argocd")
		})
	}
}

// TestArgocdInstalledContextFlag checks that the devzone context flag is added
// when the kubeconfig declares it, and only then.
func TestArgocdInstalledContextFlag(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace devzone-argocd", status: 0},
	}}
	if !argocdInstalled(r) {
		t.Fatal("argocdInstalled = false, want true")
	}
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" get namespace devzone-argocd")

	r = &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "get namespace devzone-argocd", status: 0},
	}}
	if !argocdInstalled(r) {
		t.Fatal("argocdInstalled = false, want true")
	}
	wantCalls(t, r.calls, contextsCall, "get namespace devzone-argocd")
}

// TestArgocdActive checks wanted and installed, wanted and absent, and off:
// when off no kubectl call is made at all.
func TestArgocdActive(t *testing.T) {
	t.Run("wanted and installed", func(t *testing.T) {
		dir := t.TempDir()
		modules := writeStateFile(t, dir, "argocd=on\n")
		r := &fakeRunner{replies: []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get namespace devzone-argocd", status: 0},
		}}
		if !argocdActive(r, modules) {
			t.Fatal("argocdActive = false, want true")
		}
		wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" get namespace devzone-argocd")
	})
	t.Run("wanted and absent", func(t *testing.T) {
		dir := t.TempDir()
		modules := writeStateFile(t, dir, "argocd=on\n")
		r := &fakeRunner{replies: []reply{
			{match: contextsCall, stdout: currentContext},
			{match: "get namespace devzone-argocd", status: 1},
		}}
		if argocdActive(r, modules) {
			t.Fatal("argocdActive = true, want false")
		}
		wantCalls(t, r.calls, contextsCall, "get namespace devzone-argocd")
	})
	t.Run("off makes no call", func(t *testing.T) {
		dir := t.TempDir()
		modules := writeStateFile(t, dir, "argocd=off\n")
		r := &fakeRunner{}
		if argocdActive(r, modules) {
			t.Fatal("argocdActive = true, want false")
		}
		wantCalls(t, r.calls)
	})
}

// TestArgocdQuantityKi checks every suffix, the integer divisions, the bare
// number of bytes and the values that give 0.
func TestArgocdQuantityKi(t *testing.T) {
	cases := []struct {
		q    string
		want int64
	}{
		{"1024Ki", 1024},
		{"1Ki", 1},
		{"2Mi", 2 * 1024},
		{"16384Mi", 16384 * 1024},
		{"1Gi", 1024 * 1024},
		{"1Ti", 1024 * 1024 * 1024},
		{"1000K", 1000 * 1000 / 1024},
		{"1000k", 1000 * 1000 / 1024},
		{"1M", 1000 * 1000 / 1024},
		{"1G", 1000 * 1000 * 1000 / 1024},
		{"2048", 2},
		{"9223372036854775807", 9223372036854775807 / 1024},
		{"0", 0},
		{"", 0},
		{"abc", 0},
		{"1Ei", 0},
		{"1.5Gi", 0},
	}
	for _, tc := range cases {
		t.Run(tc.q, func(t *testing.T) {
			if got := argocdQuantityKi(tc.q); got != tc.want {
				t.Fatalf("argocdQuantityKi(%q) = %d, want %d", tc.q, got, tc.want)
			}
		})
	}
}

// TestArgocdRevision checks the environment first, then the first matching
// line of package.json, the last version on that line, 0.0.0 and the missing
// file.
func TestArgocdRevision(t *testing.T) {
	cases := []struct {
		name    string
		env     string
		present bool
		content string
		want    string
	}{
		{"environment wins", "v9.9.9", true, `{"version": "1.2.3"}`, "v9.9.9"},
		{"zero version", "", true, `{"version": "0.0.0"}`, ""},
		{"real version", "", true, `{"version": "1.2.3"}`, "v1.2.3"},
		{"empty version", "", true, `"version": ""`, ""},
		{"no version field", "", true, `{"name": "devzone"}`, ""},
		{"missing file", "", false, "", ""},
		{"first matching line wins", "", true,
			"{\n  \"version\": \"1.0.0\",\n  \"version\": \"2.0.0\"\n}", "v1.0.0"},
		{"last version on a line wins", "", true,
			`{"a": "version": "1.0.0", "version": "2.0.0"}`, "v2.0.0"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if tc.present {
				if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(tc.content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("DEVZONE_ARGOCD_REVISION", tc.env)
			if got := argocdRevision(dir); got != tc.want {
				t.Fatalf("argocdRevision = %q, want %q", got, tc.want)
			}
		})
	}
}
