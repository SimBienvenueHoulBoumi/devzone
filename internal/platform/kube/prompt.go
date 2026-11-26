package kube

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// PromptCachePath returns the cache file of the Kubernetes shell prompt.
func PromptCachePath() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		base = filepath.Join(home(), ".cache")
	}
	return filepath.Join(base, "devzone-kube-prompt")
}

// PromptConfig returns the kubeconfig list used by the shell prompt.
func PromptConfig() string {
	if conf := os.Getenv("KUBECONFIG"); conf != "" {
		return conf
	}
	return configPath("config") + ":" + configPath("hote.config")
}

// Prompt renders ⎈ ctx/ns with a cache keyed on the mtime of the kubeconfig
// files, as devzone_kube_prompt did.
func (k Kube) Prompt(ctx context.Context, out io.Writer) error {
	sig := ""
	for _, file := range strings.Split(PromptConfig(), ":") {
		if file == "" {
			continue
		}
		mtime := "missing"
		if info, err := os.Stat(file); err == nil {
			mtime = strconv.FormatInt(info.ModTime().Unix(), 10)
		}
		sig += file + ":" + mtime + ";"
	}
	cache := PromptCachePath()
	if data, err := os.ReadFile(cache); err == nil {
		lines := strings.SplitN(string(data), "\n", 2)
		if len(lines) == 2 && lines[0] == sig {
			fmt.Fprintln(errOutOrDiscard(out), strings.TrimRight(lines[1], "\n"))
			return nil
		}
	}
	name := k.CurrentContext(ctx)
	result := ""
	if name != "" {
		ns := k.ContextNamespace(ctx, name)
		if ns == "" {
			ns = "default"
		}
		if k.IsLocal(name) {
			result = fmt.Sprintf("\001\033[36m\002⎈ %s/%s\001\033[0m\002", name, ns)
		} else {
			result = fmt.Sprintf("\001\033[1;31m\002⎈ %s/%s remote\001\033[0m\002", name, ns)
		}
	}
	if err := os.MkdirAll(filepath.Dir(cache), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(cache, []byte(sig+"\n"+result+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Fprintln(errOutOrDiscard(out), result)
	return nil
}
