package podcmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// fakePod replaces the Go commands of the pod: it records each call ("name arg…")
// and answers with the scripted standard output and exit status. Unknown calls
// succeed with no output.
type fakePod struct {
	calls []string
	outs  map[string]string
	codes map[string]int
}

func (f *fakePod) run(out io.Writer, args ...string) int {
	key := strings.Join(args, " ")
	f.calls = append(f.calls, key)
	if s, ok := f.outs[key]; ok {
		_, _ = io.WriteString(out, s)
	}
	return f.codes[key]
}

// has reports whether the call was made.
func (f *fakePod) has(call string) bool {
	for _, c := range f.calls {
		if c == call {
			return true
		}
	}
	return false
}

// moduleFixture is a devzone folder for the module commands: the state file
// exists (so the state is never rebuilt), the Runner is a fake, the pod is fakePod.
type moduleFixture struct {
	m      *modules
	out    *bytes.Buffer
	errOut *bytes.Buffer
	pod    *fakePod
	root   string
}

// newModuleFixture builds the module commands on a state holding the given lines.
func newModuleFixture(t *testing.T, stateLines ...string) *moduleFixture {
	t.Helper()
	root := t.TempDir()
	etat := filepath.Join(root, ".devzone.modules")
	if err := os.WriteFile(etat, []byte(strings.Join(stateLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Out: out, Err: errOut, Stdin: strings.NewReader(""), Runner: fake.New()}
	pod := &fakePod{outs: map[string]string{}, codes: map[string]int{}}
	m := &modules{
		ctx:  ctx,
		etat: etat,
		root: root,
		code: root,
		home: filepath.Join(root, "home"),
		call: pod.run,
	}
	return &moduleFixture{m: m, out: out, errOut: errOut, pod: pod, root: root}
}

// state returns the content of the state file.
func (f *moduleFixture) state(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(f.m.etat)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// marker returns the content of the failure marker of a module, "" when absent.
func (f *moduleFixture) marker(module string) string {
	data, err := os.ReadFile(f.m.markerPath(module))
	if err != nil {
		return ""
	}
	return string(data)
}

// TestChangeModuleWithoutName checks the message and status of enable with no module.
func TestChangeModuleWithoutName(t *testing.T) {
	f := newModuleFixture(t)
	if code := f.m.changeModule("on", "", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	want := "devzone : unknown module : (none) ; modules : ai kubernetes gitlab postgres argocd mysql\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", f.errOut.String(), want)
	}
}

// TestChangeModuleUnknown checks that an unknown module is refused without any change.
func TestChangeModuleUnknown(t *testing.T) {
	f := newModuleFixture(t, "ai=off")
	if code := f.m.changeModule("on", "nope", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : unknown module : nope") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if f.state(t) != "ai=off\n" {
		t.Fatalf("state changed: %q", f.state(t))
	}
}

// TestChangeModuleLLMRemoved checks the migration of the removed llm module:
// its line leaves the state, the notice is printed and the status is 1.
func TestChangeModuleLLMRemoved(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "llm=on")
	if code := f.m.changeModule("on", "llm", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.out.String(), "llm module removed") {
		t.Fatalf("stdout = %q", f.out.String())
	}
	if strings.Contains(f.state(t), "llm=") {
		t.Fatalf("llm line kept: %q", f.state(t))
	}
}

// TestMigrateLLMOnce checks that the llm line is dropped with one notice, even when a
// module is changed afterwards.
func TestMigrateLLMOnce(t *testing.T) {
	f := newModuleFixture(t, "llm=off", "ai=off")
	f.m.migrateLLM()
	f.m.migrateLLM()
	if strings.Count(f.out.String(), "llm module removed") != 1 {
		t.Fatalf("notice count wrong: %q", f.out.String())
	}
	if f.state(t) != "ai=off\n" {
		t.Fatalf("state = %q", f.state(t))
	}
}

// TestChangeModuleInPodRefused checks that a service of the pod is not installed
// from the pod: the workstation command is printed, the state does not change.
func TestChangeModuleInPodRefused(t *testing.T) {
	f := newModuleFixture(t, "gitlab=off")
	f.m.inPod = true
	if code := f.m.changeModule("on", "gitlab", nil); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	want := "devzone: in the workspace pod, gitlab is installed from the workstation: devzone workspace services enable gitlab\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", f.errOut.String(), want)
	}
	if f.state(t) != "gitlab=off\n" || len(f.pod.calls) != 0 {
		t.Fatalf("state %q, calls %v", f.state(t), f.pod.calls)
	}
}

// TestChangeModuleInPodAdminAllowed checks that the services-admin run (DEVZONE_SERVICES_ADMIN)
// installs the service from the pod.
func TestChangeModuleInPodAdminAllowed(t *testing.T) {
	f := newModuleFixture(t, "gitlab=off")
	f.m.inPod, f.m.servicesAdmin = true, true
	f.pod.codes["gitlab status"] = 0
	f.pod.outs["gitlab status"] = "not ready\n"
	if code := f.m.changeModule("on", "gitlab", nil); code != 0 {
		t.Fatalf("code %d, want 0; stderr %q", code, f.errOut.String())
	}
	if !f.pod.has("gitlab install") {
		t.Fatalf("installer not run: %v", f.pod.calls)
	}
}

// TestEnablePostgresMismatchContext checks that a --context different from the
// saved cluster is refused with the cluster hint and disables the module (#280).
func TestEnablePostgresMismatchContext(t *testing.T) {
	f := newModuleFixture(t, "cluster=kind-devzone")
	f.pod.outs["kube saved"] = "kind-devzone"
	if code := f.m.applyPostgres("on", []string{"--context", "host-cluster"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone cluster host-cluster") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if !strings.Contains(f.state(t), "postgres=off") {
		t.Fatalf("state = %q", f.state(t))
	}
}

// TestEnablePostgresUnknownArgument checks the refusal of an unknown argument.
func TestEnablePostgresUnknownArgument(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	if code := f.m.applyPostgres("on", []string{"--bogus"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	want := "devzone : unknown argument: --bogus (devzone enable postgres --context CTX [--confirm CTX])\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestEnablePostgresContextWithoutValue checks that --context without its value is refused.
func TestEnablePostgresContextWithoutValue(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	if code := f.m.applyPostgres("on", []string{"--context"}); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : context expects a context") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestApplyPostgresRestartsRelay checks that a stopped relay is restarted
// without reinstalling PostgreSQL (orchestration of the shell).
func TestApplyPostgresRestartsRelay(t *testing.T) {
	f := newModuleFixture(t, "postgres=on", "cluster=kind-devzone")
	f.pod.outs["postgres status"] = "ready on kind-devzone, relay stopped: devzone apply\n"
	f.pod.outs["kube saved"] = "kind-devzone\n"
	f.pod.outs["kube choose "] = "kind-devzone\n"
	if code := f.m.applyPostgres("on", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	want := []string{"kube saved", "kube choose ", "kube save kind-devzone", "postgres status", "postgres relay-start"}
	if strings.Join(f.pod.calls, "|") != strings.Join(want, "|") {
		t.Fatalf("calls = %v, want %v", f.pod.calls, want)
	}
	if !strings.Contains(f.out.String(), "devzone : postgres : relay restarted") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyPostgresInstallFailure checks the failure marker and the status 1 of a failed install.
func TestApplyPostgresInstallFailure(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.pod.codes["postgres install"] = 1
	f.pod.outs["postgres status"] = "absent\n"
	if code := f.m.applyPostgres("on", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if f.marker("postgres") != "postgres\n" {
		t.Fatalf("marker = %q", f.marker("postgres"))
	}
}

// TestApplyPostgresOffUninstalls checks the removal and the cleared marker.
func TestApplyPostgresOffUninstalls(t *testing.T) {
	f := newModuleFixture(t, "postgres=off")
	f.m.setMarker("postgres")
	if code := f.m.applyPostgres("off", nil); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("postgres uninstall") || f.marker("postgres") != "" {
		t.Fatalf("calls %v, marker %q", f.pod.calls, f.marker("postgres"))
	}
}

// TestConfirmRemovalAnswers checks the prompt of a removal that deletes data:
// a yes deletes the data, a refusal of postgres cancels, a refusal of mysql
// still disables.
func TestConfirmRemovalAnswers(t *testing.T) {
	cases := []struct {
		name, app, answer   string
		proceed, deleteData bool
		abortedMsg          bool
	}{
		{"postgres yes", "postgres", "y\n", true, true, false},
		{"postgres refused", "postgres", "n\n", false, false, true},
		{"mysql refused keeps data", "mysql", "\n", true, false, false},
		{"gitlab yes", "gitlab", "yes\n", true, true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newModuleFixture(t, c.app+"=on")
			f.m.interactive = true
			f.m.ctx.Stdin = strings.NewReader(c.answer)
			if got := f.m.confirmRemoval(c.app, nil); got != c.proceed {
				t.Fatalf("proceed = %v, want %v", got, c.proceed)
			}
			if f.m.deleteData != c.deleteData {
				t.Fatalf("deleteData = %v, want %v", f.m.deleteData, c.deleteData)
			}
			if strings.Contains(f.out.String(), "Aborted: nothing was deleted.") != c.abortedMsg {
				t.Fatalf("stdout = %q", f.out.String())
			}
			if !strings.Contains(f.errOut.String(), "[y/N]") {
				t.Fatalf("no prompt on stderr: %q", f.errOut.String())
			}
		})
	}
}

// TestConfirmRemovalSkipped checks that no question is asked without a terminal
// or when --yes is given: the data is then deleted only with --yes.
func TestConfirmRemovalSkipped(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.m.interactive = false
	if !f.m.confirmRemoval("postgres", nil) || f.m.deleteData {
		t.Fatalf("without a terminal: deleteData %v", f.m.deleteData)
	}
	if f.errOut.Len() != 0 {
		t.Fatalf("question asked: %q", f.errOut.String())
	}
	if !f.m.confirmRemoval("postgres", []string{"--yes"}) || !f.m.deleteData {
		t.Fatalf("--yes: deleteData %v", f.m.deleteData)
	}
}

// TestDisablePostgresDeletesWithYes checks the full removal of postgres with --yes:
// the hook of Argo CD runs first, then the uninstaller.
func TestDisablePostgresDeletesWithYes(t *testing.T) {
	f := newModuleFixture(t, "postgres=on")
	f.pod.outs["postgres status"] = "absent\n"
	if code := f.m.changeModule("off", "postgres", []string{"--yes"}); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(f.state(t), "postgres=off") {
		t.Fatalf("state = %q", f.state(t))
	}
	if !f.pod.has("argocd services-hook postgres off --yes") {
		t.Fatalf("hook not called: %v", f.pod.calls)
	}
}

// TestHookExitStatuses checks the exit status of the Argo CD hook: 0 ends the
// change, 3 falls back to the direct installer, any other status fails.
func TestHookExitStatuses(t *testing.T) {
	f := newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 0
	if code := f.m.changeModule("on", "mysql", nil); code != 0 || f.pod.has("mysql install") {
		t.Fatalf("hook 0: code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 1
	if code := f.m.changeModule("on", "mysql", nil); code != 1 {
		t.Fatalf("hook 1: code %d, want 1", code)
	}

	f = newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 3
	f.pod.outs["mysql status"] = "ready on kind-devzone\n"
	if code := f.m.changeModule("on", "mysql", nil); code != 0 {
		t.Fatalf("hook 3: code %d", code)
	}
	if !strings.Contains(f.out.String(), "devzone : mysql already active, nothing to do.") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestMysqlWithoutClusterRefused checks that mysql needs a saved cluster, with its failure marker.
func TestMysqlWithoutClusterRefused(t *testing.T) {
	f := newModuleFixture(t, "mysql=on")
	if code := f.m.applyMysql("on"); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : mysql: no cluster chosen: devzone enable mysql") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if f.marker("mysql") != "mysql\n" || !strings.Contains(f.state(t), "mysql=off") {
		t.Fatalf("marker %q, state %q", f.marker("mysql"), f.state(t))
	}
}

// TestMysqlOffKeepsVolume checks that a removal without --yes keeps the databases.
func TestMysqlOffKeepsVolume(t *testing.T) {
	f := newModuleFixture(t, "mysql=on")
	if code := f.m.applyMysql("off"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("catalog remove mysql") || f.pod.has("mysql delete-data --yes") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	f.m.deleteData = true
	if code := f.m.applyMysql("off"); code != 0 || !f.pod.has("mysql delete-data --yes") {
		t.Fatalf("with data: code %d, calls %v", code, f.pod.calls)
	}
}

// TestApplyGitlabReadyRunnerOnline checks that an active gitlab is only
// reconnected to the hosts, without the installer.
func TestApplyGitlabReadyRunnerOnline(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "ready, runner online\n"
	f.m.setMarker("gitlab")
	if code := f.m.applyGitlab("on"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.pod.has("gitlab install") || !f.pod.has("gitlab host-set") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	// failure of an old run cleared: gitlab is ready (#366)
	if f.marker("gitlab") != "" {
		t.Fatalf("marker kept: %q", f.marker("gitlab"))
	}
	if !strings.Contains(f.out.String(), "devzone : gitlab already active, nothing to do.") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyGitlabReadyWithoutRunnerInstalls checks that a ready gitlab without
// a runner online goes through the installer, and clears the marker of an old failure.
func TestApplyGitlabReadyWithoutRunnerInstalls(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "ready, no runner\n"
	f.m.setMarker("gitlab")
	if code := f.m.applyGitlab("on"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if !f.pod.has("gitlab install") || f.pod.has("gitlab host-set") {
		t.Fatalf("calls %v", f.pod.calls)
	}
	if f.marker("gitlab") != "" {
		t.Fatalf("marker kept: %q", f.marker("gitlab"))
	}
}

// TestApplyGitlabInstallFailure checks that a failed installer leaves the marker of gitlab.
func TestApplyGitlabInstallFailure(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.pod.outs["gitlab status"] = "absent\n"
	f.pod.codes["gitlab install"] = 1
	if code := f.m.applyGitlab("on"); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if f.marker("gitlab") != "gitlab\n" {
		t.Fatalf("marker = %q", f.marker("gitlab"))
	}
}

// TestApplyGitlabOff checks the removal: with --yes the data goes too, and a
// missing namespace only says so.
func TestApplyGitlabOff(t *testing.T) {
	f := newModuleFixture(t, "gitlab=on")
	f.m.deleteData = true
	if code := f.m.applyGitlab("off"); code != 0 || !f.pod.has("gitlab uninstall --yes") {
		t.Fatalf("code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "gitlab=on")
	f.pod.codes["gitlab installed"] = 1
	if code := f.m.applyGitlab("off"); code != 0 || f.pod.has("gitlab uninstall") {
		t.Fatalf("not installed: code %d, calls %v", code, f.pod.calls)
	}
	if !strings.Contains(f.out.String(), "gitlab already deactivated") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyArgocdRelayAndInstall checks the relay restart, the already-active
// message and the installer of argocd.
func TestApplyArgocdRelayAndInstall(t *testing.T) {
	f := newModuleFixture(t, "argocd=on")
	f.pod.outs["argocd status"] = "ready, relay stopped\n"
	if code := f.m.applyArgocd("on"); code != 0 || !f.pod.has("argocd relay-start") {
		t.Fatalf("relay: code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "argocd=on")
	f.pod.outs["argocd status"] = "absent\n"
	f.pod.codes["argocd install"] = 1
	if code := f.m.applyArgocd("on"); code != 1 || f.marker("argocd") != "argocd\n" {
		t.Fatalf("install: code %d, marker %q", code, f.marker("argocd"))
	}
}

// TestApplyKubernetesOff checks that the host kubeconfig is removed and
// metrics-server with it.
func TestApplyKubernetesOff(t *testing.T) {
	f := newModuleFixture(t)
	kube := filepath.Join(f.m.home, ".kube", "hote.config")
	if err := os.MkdirAll(filepath.Dir(kube), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kube, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := f.m.applyKubernetes("off"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if _, err := os.Stat(kube); !os.IsNotExist(err) {
		t.Fatalf("kubeconfig kept: %v", err)
	}
	if !f.pod.has("metrics remove") || !strings.Contains(f.out.String(), "devzone : kubernetes disabled") {
		t.Fatalf("calls %v, stdout %q", f.pod.calls, f.out.String())
	}
}

// TestApplyServiceInPod checks that apply does nothing for a service in the pod
// and clears the marker of an earlier start.
func TestApplyServiceInPod(t *testing.T) {
	f := newModuleFixture(t)
	f.m.inPod = true
	f.m.setMarker("gitlab")
	if code := f.m.applyService("gitlab"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.marker("gitlab") != "" || len(f.pod.calls) != 0 {
		t.Fatalf("marker %q, calls %v", f.marker("gitlab"), f.pod.calls)
	}
	if !strings.Contains(f.out.String(), "gitlab is installed from the workstation") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestChangeModuleAIAndCatalog checks the assistants (ai apply) and a catalog
// application, written then applied with catalog apply.
func TestChangeModuleAIAndCatalog(t *testing.T) {
	f := newModuleFixture(t, "ai=off")
	if code := f.m.changeModule("on", "ai", []string{"--x"}); code != 0 {
		t.Fatalf("ai: code %d", code)
	}
	if !f.pod.has("ai apply on --x") || !strings.Contains(f.state(t), "ai=on") {
		t.Fatalf("ai: calls %v, state %q", f.pod.calls, f.state(t))
	}

	app := filepath.Join(f.root, "catalog", "beam")
	if err := os.MkdirAll(app, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(app, "app.conf"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := f.m.changeModule("on", "beam", nil); code != 0 {
		t.Fatalf("catalog: code %d", code)
	}
	if !f.pod.has("catalog apply") || !strings.Contains(f.state(t), "beam=on") {
		t.Fatalf("catalog: calls %v, state %q", f.pod.calls, f.state(t))
	}
}

// TestApplyRunsEnabledModules checks the order of devzone apply: the migration,
// the state confirmation, the repository check, then each module that is on.
func TestApplyRunsEnabledModules(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "gitlab=off", "postgres=off", "mysql=off", "argocd=off")
	if code := f.m.apply(); code != 0 {
		t.Fatalf("code %d", code)
	}
	want := "state recovery-confirm|apply-repowarden|ai apply on"
	if strings.Join(f.pod.calls, "|") != want {
		t.Fatalf("calls = %v, want %s", f.pod.calls, want)
	}
}

// TestApplyStopsOnFailure checks that devzone apply stops at the first failing step.
func TestApplyStopsOnFailure(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "gitlab=on")
	f.pod.codes["ai apply on"] = 4
	if code := f.m.apply(); code != 4 {
		t.Fatalf("code %d, want 4", code)
	}
	if f.pod.has("gitlab status") {
		t.Fatalf("gitlab reached after the failure: %v", f.pod.calls)
	}
}

// TestRunIsEnabledStatus checks the exit status of is-enabled: 0 when on, 1 when off, 2 when unknown.
func TestRunIsEnabledStatus(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	etat := filepath.Join(root, ".devzone.modules")
	t.Setenv("DEVZONE_STATE", etat)
	if err := os.WriteFile(etat, []byte("ai=on\nmysql=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var errOut bytes.Buffer
	ctx := func(args ...string) *cli.Context {
		return &cli.Context{Args: args, Out: io.Discard, Err: &errOut, Stdin: strings.NewReader(""), Runner: fake.New()}
	}
	if code := runIsEnabled(ctx("ai")); code != 0 {
		t.Fatalf("ai: code %d, want 0", code)
	}
	if code := runIsEnabled(ctx("mysql")); code != 1 {
		t.Fatalf("mysql: code %d, want 1", code)
	}
	if code := runIsEnabled(ctx("nope")); code != 2 {
		t.Fatalf("nope: code %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "devzone : unknown module : nope") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}

// TestModuleCommandsRegistered checks that the module commands are handled by the pod binary.
func TestModuleCommandsRegistered(t *testing.T) {
	for _, name := range []string{"enable", "disable", "is-enabled", "apply"} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%s not registered", name)
		}
	}
}
