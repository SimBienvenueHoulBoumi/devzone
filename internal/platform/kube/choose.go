package kube

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// hostConfig returns the kubeconfig file of the host clusters.
func hostConfig() string {
	if conf := os.Getenv("DEVZONE_KUBE_HOST"); conf != "" {
		return conf
	}
	return configPath("hote.config")
}

// IsDedicated reports whether name is the dedicated kind cluster of this instance.
func IsDedicated(name string) bool {
	return name == "kind-devzone"+instanceSuffix()
}

// Candidates lists the host clusters that answer, local first, then the
// dedicated kind cluster, then the remote host clusters, as cluster_candidates.
func (k Kube) Candidates(ctx context.Context) ([]string, error) {
	host := hostConfig()
	names, err := k.HostContexts(ctx, host)
	if err != nil {
		return nil, err
	}
	var local, remote []string
	for _, name := range names {
		if IsDedicated(name) {
			continue
		}
		if k.IsLocal(name) && k.ClusterReachable(ctx, name) {
			local = append(local, name)
		} else if !k.IsLocal(name) && k.ClusterReachable(ctx, name) {
			remote = append(remote, name)
		}
	}
	out := append(local, "kind-devzone"+instanceSuffix())
	return append(out, remote...), nil
}

// Menu prints the cluster menu on errOut and returns the chosen candidate. An
// empty answer means the first candidate, as Enter did in the shell.
func (k Kube) Menu(ctx context.Context, candidates []string, stdin io.Reader, out, errOut io.Writer) (string, int) {
	if errOut != nil {
		fmt.Fprintln(errOut, "devzone : on which cluster should the devzone services be installed?")
		for i, name := range candidates {
			switch {
			case IsDedicated(name):
				fmt.Fprintf(errOut, "  %d) %s   dedicated kind cluster, in the container (default)\n", i+1, name)
			case k.IsLocal(name):
				fmt.Fprintf(errOut, "  %d) %s   local cluster\n", i+1, name)
			default:
				fmt.Fprintf(errOut, "  %d) %s   remote cluster\n", i+1, name)
			}
		}
		if !isFile(hostConfig()) {
			fmt.Fprintln(errOut, "  (host clusters not visible: devzone enable kubernetes)")
		}
		fmt.Fprint(errOut, "Number [1]: ")
	}
	answer := ""
	if stdin != nil {
		line, _ := bufio.NewReader(stdin).ReadString('\n')
		answer = strings.TrimRight(line, "\r\n")
	}
	if answer == "" {
		answer = "1"
	}
	number, err := strconv.Atoi(answer)
	if err != nil || number <= 0 {
		fmt.Fprintf(errOutOrDiscard(errOut), "devzone : invalid choice: %s\n", answer)
		return "", 2
	}
	if number > len(candidates) {
		fmt.Fprintf(errOutOrDiscard(errOut), "devzone : invalid choice: %s\n", answer)
		return "", 2
	}
	return candidates[number-1], 0
}

// errOutOrDiscard keeps a refusal message writable when no error writer is set.
func errOutOrDiscard(errOut io.Writer) io.Writer {
	if errOut == nil {
		return io.Discard
	}
	return errOut
}

// ChooseOptions carries the inputs of one cluster choice: the requested
// context, its confirmation, the saved context and the test/CI confirmation.
type ChooseOptions struct {
	Wanted      string
	Confirm     string
	Saved       string
	Remote      string
	Interactive bool
	Answer      string
	Stdin       io.Reader
	Out         io.Writer
	Err         io.Writer
}

// Choose validates a requested context, or returns the saved choice, presents
// the menu, or falls back to the local default, as cluster_choose did.
func (k Kube) Choose(ctx context.Context, opts ChooseOptions) (string, int) {
	if opts.Wanted != "" {
		candidates, err := k.Candidates(ctx)
		if err != nil {
			return "", 2
		}
		found := false
		for _, name := range candidates {
			if name == opts.Wanted {
				found = true
				break
			}
		}
		if !found {
			fmt.Fprintf(errOutOrDiscard(opts.Err), "devzone : unknown or unreachable cluster: %s; candidates: %s\n",
				opts.Wanted, strings.Join(candidates, " ")+" ")
			return "", 2
		}
		if !k.IsLocal(opts.Wanted) {
			confirm := opts.Confirm
			if confirm == "" {
				confirm = opts.Remote
			}
			reason := "--confirm " + opts.Wanted
			if opts.Confirm == "" && opts.Remote != "" {
				reason = "DEVZONE_CLUSTER_REMOTE must be exactly " + opts.Wanted
			}
			if confirm == "" && opts.Interactive {
				fmt.Fprintf(errOutOrDiscard(opts.Err), "remote cluster: %s ; type its name to confirm: ", opts.Wanted)
				confirm = opts.Answer
				if confirm == "" && opts.Stdin != nil {
					line, _ := bufio.NewReader(opts.Stdin).ReadString('\n')
					confirm = strings.TrimRight(line, "\r\n")
				}
			}
			if confirm != opts.Wanted {
				fmt.Fprintf(errOutOrDiscard(opts.Err), "devzone : remote cluster refused: %s (%s)\n", opts.Wanted, reason)
				return "", 2
			}
		}
		return opts.Wanted, 0
	}
	if opts.Saved != "" {
		return opts.Saved, 0
	}
	if opts.Interactive {
		candidates, err := k.Candidates(ctx)
		if err != nil {
			return "", 2
		}
		return k.Menu(ctx, candidates, opts.Stdin, opts.Out, opts.Err)
	}
	if current := k.HostCurrentContext(ctx, hostConfig()); current != "" &&
		k.IsLocal(current) && k.ClusterReachable(ctx, current) {
		return current, 0
	}
	return "kind-devzone" + instanceSuffix(), 0
}

// SavedContext returns the last cluster= line of the state file.
func SavedContext(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	saved := ""
	for _, line := range strings.Split(string(data), "\n") {
		if value, ok := strings.CutPrefix(line, "cluster="); ok {
			saved = value
		}
	}
	return saved
}

// SaveContext records the chosen services cluster with the same lock and backup
// as the state command of the shell launcher.
func SaveContext(path, name string) error {
	return state.At(path).Set("cluster", name)
}

// hostConfigPath returns the host kubeconfig under the given home, for tests.
func hostConfigPath(home string) string {
	return filepath.Join(home, ".kube", "hote.config")
}
