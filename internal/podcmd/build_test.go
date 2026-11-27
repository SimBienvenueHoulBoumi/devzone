package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// runBuildWithRunner runs the registered build command with the given arguments
// and runner, and returns its standard output, error output and exit status.
func runBuildWithRunner(t *testing.T, args []string, r exec.Runner) (string, string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: args, Out: &out, Err: &errOut, Runner: r}
	code, ok := Registry.Run(append([]string{"build"}, args...), ctx)
	if !ok {
		t.Fatalf("build is not handled by the pod binary")
	}
	return out.String(), errOut.String(), code
}

// TestBuildIsHandled checks that the build command of the pod runs in Go, not
// in a shell.
func TestBuildIsHandled(t *testing.T) {
	if _, ok := Registry.Lookup("build"); !ok {
		t.Fatalf("build is not registered")
	}
}

// TestBuildRefusedOutsidePod checks that a build is refused outside the
// Kubernetes workspace pod, with the status of the removed script.
func TestBuildRefusedOutsidePod(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "")
	var out, errOut bytes.Buffer
	if code := runBuild(&cli.Context{Out: &out, Err: &errOut, Runner: fake.New()}); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "only in the Kubernetes workspace pod") {
		t.Fatalf("errOut = %q", errOut.String())
	}
}

// TestBuildUsage checks the refusal of a missing folder argument.
func TestBuildUsage(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	_, errOut, code := runBuildWithRunner(t, []string{}, fake.New())
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "usage: devzone build") {
		t.Fatalf("errOut = %q", errOut)
	}
}

// TestBuildUnknownArgument checks the refusal of an argument other than the
// optional image tag.
func TestBuildUnknownArgument(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	_, errOut, code := runBuildWithRunner(t, []string{"some", "--nope"}, fake.New())
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "unknown argument: --nope") {
		t.Fatalf("errOut = %q", errOut)
	}
}

// TestBuildTagRequiresName checks that an image tag without a name is refused.
func TestBuildTagRequiresName(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	_, errOut, code := runBuildWithRunner(t, []string{"some", "--tag"}, fake.New())
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "--tag requires a name") {
		t.Fatalf("errOut = %q", errOut)
	}
}

// TestBuildDirectoryNotFound checks the refusal of a folder that does not exist.
func TestBuildDirectoryNotFound(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	_, errOut, code := runBuildWithRunner(t, []string{"missing-folder"}, fake.New())
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "directory not found: missing-folder") {
		t.Fatalf("errOut = %q", errOut)
	}
}

// TestBuildDockerfileMissing checks the refusal when the folder has no
// Dockerfile.
func TestBuildDockerfileMissing(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	_, errOut, code := runBuildWithRunner(t, []string{t.TempDir()}, fake.New())
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "Dockerfile not found in") {
		t.Fatalf("errOut = %q", errOut)
	}
}

// TestBuildRunsBuildctlCacheonly checks the buildctl call of the pod: the
// default address of the BuildKit sidecar, the cache-only output.
func TestBuildRunsBuildctlCacheonly(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("buildctl", []string{
		"--addr", "tcp://127.0.0.1:1234",
		"build",
		"--frontend", "dockerfile.v0",
		"--local", "context=" + dir,
		"--local", "dockerfile=" + dir,
		"--output", "type=cacheonly",
	}, exec.Result{Code: 0})
	_, _, code := runBuildWithRunner(t, []string{dir}, r)
	if code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	calls := r.Calls()
	if len(calls) != 1 {
		t.Fatalf("calls = %d, want 1", len(calls))
	}
	if calls[0].Name != "buildctl" {
		t.Fatalf("call name = %q, want buildctl", calls[0].Name)
	}
	want := []string{
		"--addr", "tcp://127.0.0.1:1234",
		"build",
		"--frontend", "dockerfile.v0",
		"--local", "context=" + dir,
		"--local", "dockerfile=" + dir,
		"--output", "type=cacheonly",
	}
	if strings.Join(calls[0].Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %v, want %v", calls[0].Args, want)
	}
}

// TestBuildTagImageOutput checks the image output of a tagged build.
func TestBuildTagImageOutput(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM scratch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("buildctl", []string{
		"--addr", "tcp://127.0.0.1:1234",
		"build",
		"--frontend", "dockerfile.v0",
		"--local", "context=" + dir,
		"--local", "dockerfile=" + dir,
		"--output", "type=image,name=app:1,push=false",
	}, exec.Result{Code: 0})
	_, _, code := runBuildWithRunner(t, []string{dir, "--tag", "app:1"}, r)
	if code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
}

// TestBuildKitVersionConsistency checks that the pinned version of the BuildKit
// client agrees between the Dockerfile, versions.env and the workspace chart.
func TestBuildKitVersionConsistency(t *testing.T) {
	dockerfile, err := os.ReadFile("../../.devcontainer/Dockerfile")
	if err != nil {
		t.Fatalf("read the Dockerfile: %v", err)
	}
	dockerfileText := string(dockerfile)
	for _, fragment := range []string{"moby/buildkit", "BUILDKIT_VERSION", "buildctl", "sha256sum -c"} {
		if !strings.Contains(dockerfileText, fragment) {
			t.Fatalf("Dockerfile misses %q", fragment)
		}
	}
	envData, err := os.ReadFile("../../.devcontainer/versions.env")
	if err != nil {
		t.Fatalf("read versions.env: %v", err)
	}
	envVersion := ""
	for _, line := range strings.Split(string(envData), "\n") {
		if version, ok := strings.CutPrefix(line, "BUILDKIT_VERSION="); ok && envVersion == "" {
			envVersion = version
		}
	}
	dfVersion := ""
	for _, line := range strings.Split(string(dockerfile), "\n") {
		if version, ok := strings.CutPrefix(line, "ARG BUILDKIT_VERSION="); ok && dfVersion == "" {
			dfVersion = version
		}
	}
	values, err := os.ReadFile("../../charts/devzone-workspace/values.yaml")
	if err != nil {
		t.Fatalf("read the chart values: %v", err)
	}
	chartImage := ""
	for _, line := range strings.Split(string(values), "\n") {
		if image, ok := strings.CutPrefix(line, "  image: moby/buildkit:"); ok && chartImage == "" {
			chartImage = image
		}
	}
	chartVersion := ""
	if len(chartImage) > 1 && chartImage[0] == 'v' {
		parts := strings.SplitN(chartImage[1:], "-", 2)
		if len(parts) > 0 {
			chartVersion = parts[0]
		}
	}
	if envVersion == "" || envVersion != dfVersion || envVersion != chartVersion {
		t.Fatalf("BuildKit versions: env = %q, Dockerfile = %q, chart = %q", envVersion, dfVersion, chartVersion)
	}
}
