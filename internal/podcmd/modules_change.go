package podcmd

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// llmRemovedMessage is the migration notice of the llm module, removed (#669).
const llmRemovedMessage = "devzone : llm module removed: devzone no longer hosts a model; the host (Ollama) models are detected instead (devzone ai). To free the disk: kubectl delete namespace devzone-llm"

// goCall runs a pod command of the Go binary: args[0] names the command and
// args[1:] are its arguments; its standard output goes to out. It is the Go
// equivalent of the shell calling "$ICI/devzone <args>", and the tests replace it.
type goCall func(out io.Writer, args ...string) int

// modules runs the module commands (enable, disable, is-enabled, apply) on the
// state file of the instance. The commands of the other modules are reached
// through call, so the tests check the sequence of calls without running them.
type modules struct {
	ctx           *cli.Context
	etat          string // state file of the instance (DEVZONE_STATE)
	root          string // devzone folder
	code          string // folder of the shell entry point: catalog/<app>/app.conf
	home          string
	inPod         bool // devzone runs in the Kubernetes workspace pod (#528)
	servicesAdmin bool // DEVZONE_SERVICES_ADMIN: run by services-admin with a temporary account
	interactive   bool // a confirmation can be read (DEVZONE_INTERACTIVE=1 or a terminal)
	deleteData    bool // set by the confirmation of a removal, read by the uninstallers
	call          goCall
}

// newModules builds the module commands of the pod for the devzone folders and
// exports DEVZONE_STATE, as the shell did before calling its commands.
func newModules(ctx *cli.Context) *modules {
	root := devzoneRoot()
	etat := os.Getenv("DEVZONE_STATE")
	if etat == "" {
		etat = filepath.Join(root, ".devzone.modules")
	}
	_ = os.Setenv("DEVZONE_STATE", etat)
	return &modules{
		ctx:           ctx,
		etat:          etat,
		root:          root,
		code:          codeRoot(),
		home:          os.Getenv("HOME"),
		inPod:         os.Getenv("DEVZONE_WORKSPACE") == "kubernetes",
		servicesAdmin: os.Getenv("DEVZONE_SERVICES_ADMIN") != "",
		interactive:   os.Getenv("DEVZONE_INTERACTIVE") == "1" || stdinTerminal(),
		call: func(out io.Writer, args ...string) int {
			return runPodCommand(ctx, out, args...)
		},
	}
}

// runPodCommand runs the Go command args[0] with args[1:] and writes its
// standard output to out; its errors go to the context.
func runPodCommand(ctx *cli.Context, out io.Writer, args ...string) int {
	sub := &cli.Context{Args: args[1:], Out: out, Err: ctx.Err, Stdin: ctx.Stdin, Runner: ctx.Runner}
	switch args[0] {
	case "ai":
		return runAI(sub)
	case "apply-repowarden":
		return runApplyRepowarden(sub)
	case "argocd":
		return runArgocd(sub)
	case "catalog":
		return runCatalog(sub)
	case "gitlab":
		return runGitlab(sub)
	case "kube":
		return runKube(sub)
	case "metrics":
		return runMetrics(sub)
	case "mysql":
		return runMysql(sub)
	case "postgres":
		return runPostgres(sub)
	case "state":
		return runState(sub)
	}
	return 127
}

// stdinTerminal reports whether stdin is a terminal, like [ -t 0 ] of the shell
// (a character device that is not the null device).
func stdinTerminal() bool {
	info, err := os.Stdin.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	if null, err := os.Stat(os.DevNull); err == nil && os.SameFile(info, null) {
		return false
	}
	return true
}

// isModule reports whether name is a module of the instance (is_known).
func isModule(name string) bool {
	for _, m := range moduleNames {
		if m == name {
			return true
		}
	}
	return false
}

// fileExists reports whether path is an existing file.
func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// init creates the state file when it is missing (init_state): the old global
// state is taken over, the backup restored, else the state is rebuilt from the
// services cluster or written with the defaults.
func (m *modules) init() error {
	return state.At(m.etat).Init(moduleNames, osRunner(m.ctx), m.home, credentialsFound, warnFunc(m.ctx))
}

// value returns "on" when key is on in the state file, "off" otherwise (value_of).
func (m *modules) value(key string) string {
	_ = m.init()
	if state.At(m.etat).Get(key) == "on" {
		return "on"
	}
	return "off"
}

// writeValue sets key=value in the state file (write_value): 1 on failure.
func (m *modules) writeValue(key, value string) int {
	if err := m.init(); err != nil {
		fmt.Fprintln(m.ctx.Err, err)
		return 1
	}
	if err := state.At(m.etat).Set(key, value); err != nil {
		fmt.Fprintln(m.ctx.Err, err)
		return 1
	}
	return 0
}

// removeKey removes a key from the state file (remove_key): the configuration
// of a service only exists while it is chosen (#242).
func (m *modules) removeKey(key string) int {
	if err := m.init(); err != nil {
		fmt.Fprintln(m.ctx.Err, err)
		return 1
	}
	if err := state.At(m.etat).Delete(key); err != nil {
		fmt.Fprintln(m.ctx.Err, err)
		return 1
	}
	return 0
}

// removeLLMLine drops the llm= line of the state file; it reports whether a line was there.
func (m *modules) removeLLMLine() bool {
	if !fileExists(m.etat) {
		return false
	}
	if _, ok := state.At(m.etat).GetOK("llm"); !ok {
		return false
	}
	if err := state.At(m.etat).Delete("llm"); err != nil {
		fmt.Fprintln(m.ctx.Err, err)
	}
	return true
}

// migrateLLM drops the llm line once and reports the removal (migrate_llm, #669).
func (m *modules) migrateLLM() {
	if m.removeLLMLine() {
		fmt.Fprintln(m.ctx.Out, llmRemovedMessage)
	}
}

// markerPath is the failure marker of a module, next to the state file: the
// state shows it at each startup.
func (m *modules) markerPath(module string) string {
	return m.etat + "-failed-" + module
}

// setMarker records a failure of a module (its content is the module name).
func (m *modules) setMarker(module string) {
	_ = os.WriteFile(m.markerPath(module), []byte(module+"\n"), 0o644)
}

// clearMarker removes the failure marker of a module, if any.
func (m *modules) clearMarker(module string) {
	_ = os.Remove(m.markerPath(module))
}

// capture runs a pod command and returns its standard output without the
// trailing newlines, like $(...), with the exit status.
func (m *modules) capture(args ...string) (string, int) {
	var buf bytes.Buffer
	code := m.call(&buf, args...)
	return strings.TrimRight(buf.String(), "\n"), code
}

// clusterSaved returns the services cluster kept in the state (cluster=).
func (m *modules) clusterSaved() string {
	return state.At(m.etat).Get("cluster")
}

// confirmRemoval asks before a removal that deletes data (confirm_removal). It
// reports whether the change goes on; a refusal of postgres cancels it, mysql
// and gitlab still disable (the data is kept). The answer is read from stdin.
func (m *modules) confirmRemoval(app string, extra []string) bool {
	m.deleteData = false
	if m.value(app) != "on" {
		return true
	}
	for _, arg := range extra {
		if arg == "--yes" {
			m.deleteData = true
		}
	}
	if m.deleteData || !m.interactive {
		return true
	}
	switch app {
	case "mysql":
		fmt.Fprint(m.ctx.Err, "Disabling mysql removes the server; the volume and databases stay. Also delete the devzone-mysql namespace and its volumes? [y/N] ")
	case "gitlab":
		fmt.Fprint(m.ctx.Err, "Disabling gitlab keeps the Rails secret (browser sessions stay valid at reinstall). Also delete the Rails secret? [y/N] ")
	default:
		fmt.Fprintf(m.ctx.Err, "Disabling %s deletes all its databases. Continue? [y/N] ", app)
	}
	answer := readLine(m.ctx.Stdin)
	switch answer {
	case "y", "Y", "yes":
		m.deleteData = true
		return true
	}
	switch app {
	case "mysql", "gitlab":
		return true
	}
	fmt.Fprintln(m.ctx.Out, "Aborted: nothing was deleted.")
	return false
}

// readLine reads one line of input like the shell `read -r`; empty on EOF.
func readLine(in io.Reader) string {
	if in == nil {
		return ""
	}
	line, _ := bufio.NewReader(in).ReadString('\n')
	return strings.TrimRight(line, "\r\n")
}

// changeModule runs enable (verb "on") or disable (verb "off") of a module
// with its extra arguments (change_module).
func (m *modules) changeModule(verb, module string, extra []string) int {
	errOut := m.ctx.Err
	if module == "" {
		fmt.Fprintf(errOut, "devzone : unknown module : (none) ; modules : %s\n", strings.Join(moduleNames, " "))
		return 1
	}
	// llm removed (#669): migration message, never unknown module.
	if module == "llm" {
		_ = m.init()
		m.removeLLMLine()
		fmt.Fprintln(m.ctx.Out, llmRemovedMessage)
		return 1
	}
	m.migrateLLM()
	if !isModule(module) {
		// An application of the catalog: the line is written, then applied
		if fileExists(filepath.Join(m.code, "catalog", module, "app.conf")) {
			m.writeValue(module, verb)
			return m.call(m.ctx.Out, "catalog", "apply")
		}
		fmt.Fprintf(errOut, "devzone : unknown module : %s ; modules : %s\n", module, strings.Join(moduleNames, " "))
		return 1
	}
	// In the Kubernetes workspace pod the services are installed from the
	// workstation (#528): the pod has no administrator access to the cluster.
	if m.inPod && serviceModule(module) && !m.servicesAdmin {
		if verb == "on" {
			fmt.Fprintf(errOut, "devzone: in the workspace pod, %s is installed from the workstation: devzone workspace services enable %s\n", module, module)
		} else {
			fmt.Fprintf(errOut, "devzone: in the workspace pod, %s is removed from the workstation: devzone workspace services disable %s\n", module, module)
		}
		return 2
	}
	if verb == "off" && (module == "postgres" || module == "mysql" || module == "gitlab") {
		if !m.confirmRemoval(module, extra) {
			return 0
		}
	}
	m.writeValue(module, verb)
	// Services held by Argo CD (#559): postgres and mysql, plus the release of
	// the Applications when argocd is turned off. Hook exit 0 is done by Argo CD,
	// 3 is the direct helm path, anything else is a failure.
	if module == "postgres" || module == "mysql" || (module == "argocd" && verb == "off") {
		code := m.call(m.ctx.Out, append([]string{"argocd", "services-hook", module, verb}, extra...)...)
		if code == 0 {
			return 0
		}
		if code != 3 {
			return 1
		}
	}
	// The assistant part of enable/disable ai is the Go command ai apply (#882).
	if module == "ai" {
		return m.call(m.ctx.Out, append([]string{"ai", "apply", verb}, extra...)...)
	}
	return m.applyModule(verb, module, extra)
}

// applyModule installs ("on") or removes ("off") a module (apply_<module>).
func (m *modules) applyModule(verb, module string, extra []string) int {
	switch module {
	case "kubernetes":
		return m.applyKubernetes(verb)
	case "gitlab":
		return m.applyGitlab(verb)
	case "postgres":
		return m.applyPostgres(verb, extra)
	case "argocd":
		return m.applyArgocd(verb)
	case "mysql":
		return m.applyMysql(verb)
	}
	return 0
}

// apply runs the module steps of devzone apply: the migrations, the
// confirmation of the state, the repository, then each module that is on.
func (m *modules) apply() int {
	m.migrateLLM()
	if code := m.call(m.ctx.Out, "state", "recovery-confirm"); code != 0 {
		return code
	}
	if code := m.call(m.ctx.Out, "apply-repowarden"); code != 0 {
		return code
	}
	if m.value("ai") != "off" {
		if code := m.call(m.ctx.Out, "ai", "apply", "on"); code != 0 {
			return code
		}
	}
	// gitlab, postgres, argocd: installed from the workstation in the
	// Kubernetes workspace pod (#528), by their installer elsewhere
	if m.value("gitlab") != "off" {
		if code := m.applyService("gitlab"); code != 0 {
			return code
		}
	}
	if m.value("postgres") != "off" {
		if code := m.applyService("postgres"); code != 0 {
			return code
		}
	}
	if m.value("mysql") != "off" {
		if code := m.applyMysql("on"); code != 0 {
			return code
		}
	}
	if m.value("argocd") != "off" {
		if code := m.applyService("argocd"); code != 0 {
			return code
		}
	}
	return 0
}

// applyService installs a service module when devzone apply starts it. In the
// pod nothing is installed (the workstation does it, #528) and the failure
// marker of an earlier start is cleared (apply_service).
func (m *modules) applyService(module string) int {
	if m.inPod {
		m.clearMarker(module)
		fmt.Fprintf(m.ctx.Out, "devzone: %s is installed from the workstation (devzone workspace services enable %s): nothing to do in the pod\n", module, module)
		return 0
	}
	return m.applyModule("on", module, nil)
}

// applyKubernetes connects the clusters from the workstation (nothing to run on
// "on"); "off" removes the host kubeconfig and metrics-server (apply_kubernetes).
func (m *modules) applyKubernetes(verb string) int {
	if verb == "on" {
		return 0
	}
	_ = os.Remove(filepath.Join(m.home, ".kube", "hote.config"))
	// metrics-server removed from the clusters where devzone installed it
	_ = m.call(m.ctx.Out, "metrics", "remove")
	fmt.Fprintln(m.ctx.Out, "devzone : kubernetes disabled")
	return 0
}

// applyGitlab installs or removes the GitLab module (apply_gitlab). The
// installer is skipped when the state is ready and the runner online.
func (m *modules) applyGitlab(verb string) int {
	out := m.ctx.Out
	if verb == "on" {
		current, _ := m.capture("gitlab", "status")
		if strings.Contains(current, "ready") && strings.Contains(current, "runner online") {
			fmt.Fprintln(out, "devzone : gitlab already active, nothing to do.")
			// /etc/hosts regenerated when the pod starts: gitlab.localhost is set again here too
			if code := m.call(out, "gitlab", "host-set"); code != 0 {
				return code
			}
			// Failure of an old run cleared: gitlab is ready (#366)
			m.clearMarker("gitlab")
			return 0
		}
		fmt.Fprintln(out, "devzone : activating gitlab via its installer…")
		if m.call(out, "gitlab", "install") != 0 {
			m.setMarker("gitlab")
			return 1
		}
		m.clearMarker("gitlab")
		return 0
	}
	// Disable gitlab only if its namespace still exists
	if m.call(out, "gitlab", "installed") == 0 {
		fmt.Fprintln(out, "devzone : deactivating gitlab…")
		if m.deleteData {
			return m.call(out, "gitlab", "uninstall", "--yes")
		}
		return m.call(out, "gitlab", "uninstall")
	}
	fmt.Fprintln(out, "devzone : gitlab already deactivated (no devzone-gitlab namespace).")
	return 0
}

// applyPostgres installs the shared PostgreSQL (#280) on the cluster chosen at
// the first activation (--context, --confirm), or removes it (apply_postgres).
func (m *modules) applyPostgres(verb string, args []string) int {
	out, errOut := m.ctx.Out, m.ctx.Err
	if verb != "on" {
		if code := m.call(out, "postgres", "uninstall"); code != 0 {
			return code
		}
		m.clearMarker("postgres")
		return 0
	}
	wanted, confirmCtx, expect := "", "", ""
	for _, arg := range args {
		if expect != "" {
			switch expect {
			case "context":
				wanted = arg
			case "confirm":
				confirmCtx = arg
			}
			expect = ""
			continue
		}
		switch arg {
		case "--context":
			expect = "context"
		case "--confirm":
			expect = "confirm"
		default:
			fmt.Fprintf(errOut, "devzone : unknown argument: %s (devzone enable postgres --context CTX [--confirm CTX])\n", arg)
			m.writeValue("postgres", "off")
			return 2
		}
	}
	if expect != "" {
		fmt.Fprintf(errOut, "devzone : %s expects a context\n", expect)
		m.writeValue("postgres", "off")
		return 2
	}
	actual, _ := m.capture("kube", "saved")
	if wanted != "" && actual != "" && wanted != actual {
		fmt.Fprintf(errOut, "devzone : devzone services are on %s; to change: devzone cluster %s\n", actual, wanted)
		m.writeValue("postgres", "off")
		return 2
	}
	chooseArgs := []string{"kube", "choose", wanted}
	if confirmCtx != "" {
		chooseArgs = append(chooseArgs, "--confirm", confirmCtx)
	}
	chosen, code := m.capture(chooseArgs...)
	if code != 0 {
		m.writeValue("postgres", "off")
		return 2
	}
	// Choice kept before the installation: a resume targets the same cluster
	if code := m.call(out, "kube", "save", chosen); code != 0 {
		return code
	}
	current, _ := m.capture("postgres", "status")
	// "relay stopped" first: this line also starts with "ready on"
	switch {
	case strings.Contains(current, "relay stopped"):
		if code := m.call(out, "postgres", "relay-start"); code != 0 {
			return code
		}
		fmt.Fprintln(out, "devzone : postgres : relay restarted")
	case strings.HasPrefix(current, "ready on"):
		fmt.Fprintln(out, "devzone : postgres already active, nothing to do.")
	default:
		if m.call(out, "postgres", "install") != 0 {
			m.setMarker("postgres")
			return 1
		}
	}
	m.clearMarker("postgres")
	return 0
}

// applyArgocd starts Argo CD in the services cluster, reached through the relay
// 127.0.0.1:8443; a failure is marked in the state (apply_argocd, #411).
func (m *modules) applyArgocd(verb string) int {
	out := m.ctx.Out
	if verb != "on" {
		if code := m.call(out, "argocd", "uninstall"); code != 0 {
			return code
		}
		m.clearMarker("argocd")
		return 0
	}
	current, _ := m.capture("argocd", "status")
	// "relay stopped" first: this line also starts with "ready"
	switch {
	case strings.Contains(current, "relay stopped"):
		if code := m.call(out, "argocd", "relay-start"); code != 0 {
			return code
		}
		fmt.Fprintln(out, "devzone : argocd : relay restarted")
	case strings.HasPrefix(current, "ready"):
		fmt.Fprintln(out, "devzone : argocd already active, nothing to do.")
	default:
		if m.call(out, "argocd", "install") != 0 {
			m.setMarker("argocd")
			return 1
		}
	}
	m.clearMarker("argocd")
	return 0
}

// applyMysql starts the catalog MySQL (#414) on the cluster kept in the state,
// or removes it: the volume and the databases stay unless DELETE_DATA (apply_mysql).
func (m *modules) applyMysql(verb string) int {
	out, errOut := m.ctx.Out, m.ctx.Err
	if verb == "on" {
		if m.clusterSaved() == "" {
			fmt.Fprintln(errOut, "devzone : mysql: no cluster chosen: devzone enable mysql")
			m.writeValue("mysql", "off")
			m.setMarker("mysql")
			return 2
		}
		current, _ := m.capture("mysql", "status")
		// "relay stopped" first: this line also starts with "ready on"
		switch {
		case strings.Contains(current, "relay stopped"):
			if code := m.call(out, "mysql", "relay-start"); code != 0 {
				return code
			}
			fmt.Fprintln(out, "devzone : mysql: relay restarted")
		case strings.HasPrefix(current, "ready on"):
			fmt.Fprintln(out, "devzone : mysql already active, nothing to do.")
		default:
			if m.call(out, "mysql", "install") != 0 {
				m.setMarker("mysql")
				return 1
			}
		}
		m.clearMarker("mysql")
		return 0
	}
	// Removal without deleting the data: volume kept (#441); the databases
	// only leave with a yes (confirmRemoval)
	if code := m.call(out, "catalog", "remove", "mysql"); code != 0 {
		return code
	}
	if m.deleteData {
		if code := m.call(out, "mysql", "delete-data", "--yes"); code != 0 {
			return code
		}
	}
	m.clearMarker("mysql")
	return 0
}

// runEnable handles "devzone enable <module> [args]" in Go (change_module on).
func runEnable(ctx *cli.Context) int {
	return runModuleChange(ctx, "on")
}

// runDisable handles "devzone disable <module> [args]" in Go (change_module off).
func runDisable(ctx *cli.Context) int {
	return runModuleChange(ctx, "off")
}

func runModuleChange(ctx *cli.Context, verb string) int {
	module, extra := "", []string{}
	if len(ctx.Args) > 0 {
		module, extra = ctx.Args[0], ctx.Args[1:]
	}
	return newModules(ctx).changeModule(verb, module, extra)
}

// runIsEnabled handles "devzone is-enabled <module>": 0 when the module is on,
// 1 when it is off, without writing anything but the initial state (value_of).
func runIsEnabled(ctx *cli.Context) int {
	module := first(ctx.Args)
	if !isModule(module) {
		if module == "" {
			module = "(none)"
		}
		fmt.Fprintf(ctx.Err, "devzone : unknown module : %s\n", module)
		return 2
	}
	if newModules(ctx).value(module) == "on" {
		return 0
	}
	return 1
}

// runApply handles "devzone apply" in Go: the modules that are on are installed
// or started again.
func runApply(ctx *cli.Context) int {
	return newModules(ctx).apply()
}
