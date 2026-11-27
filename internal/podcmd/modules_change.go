package podcmd

import (
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
