package ai

import (
	"io"
	"os"
	"path/filepath"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Options carries the dependencies and the environment of the AI commands.
type Options struct {
	Runner          dzexec.Runner
	Out             io.Writer
	Err             io.Writer
	Home            string
	URL             string
	Registry        string
	Measures        string
	HostModel       string
	DevcontainerDir string
	StateFile       string
	Packages        []string
	Names           []string
}

// devcontainerDir returns the installed code folder holding the templates.
func (o Options) devcontainerDir() string {
	if o.DevcontainerDir != "" {
		return o.DevcontainerDir
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	wd, _ := os.Getwd()
	return filepath.Join(wd, ".devcontainer")
}

// assistants returns the pinned packages and their binary names.
func (o Options) assistants() ([]string, []string) {
	if len(o.Packages) > 0 {
		return o.Packages, o.Names
	}
	return []string{claudePackage, opencodePackage}, []string{"claude", "opencode"}
}

// failureMarker returns the path of the marker of a failed module.
func (o Options) failureMarker(module string) string {
	if o.StateFile != "" {
		return o.StateFile + "-failed-" + module
	}
	return filepath.Join(os.TempDir(), "devzone-failed-"+module)
}

// runner returns the injected runner or the process backed one.
func (o Options) runner() dzexec.Runner {
	if o.Runner != nil {
		return o.Runner
	}
	return dzexec.ExecRunner{}
}

// out returns the output writer, discarding when none was given.
func (o Options) out() io.Writer {
	if o.Out != nil {
		return o.Out
	}
	return io.Discard
}

// errOut returns the error writer, discarding when none was given.
func (o Options) errOut() io.Writer {
	if o.Err != nil {
		return o.Err
	}
	return io.Discard
}

// home returns the home directory used for configuration files.
func (o Options) home() string {
	if o.Home != "" {
		return o.Home
	}
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	return "."
}

// url returns the Ollama base address, without a trailing slash.
func (o Options) url() string {
	u := o.URL
	if u == "" {
		u = os.Getenv("DEVZONE_OLLAMA_URL")
	}
	if u == "" {
		u = "http://" + hostAlias + ":11434"
	}
	return trimSlash(u)
}

// registryURL returns the manifest registry address.
func (o Options) registryURL() string {
	u := o.Registry
	if u == "" {
		u = os.Getenv("DEVZONE_OLLAMA_REGISTRY")
	}
	if u == "" {
		u = "https://registry.ollama.ai"
	}
	return trimSlash(u)
}

// measuresFile returns the JSON file of the model measurements.
func (o Options) measuresFile() string {
	if o.Measures != "" {
		return o.Measures
	}
	if v := os.Getenv("DEVZONE_AI_MEASURES"); v != "" {
		return v
	}
	return filepath.Join(o.home(), ".config", "devzone", "ai-measures.json")
}

// hostModel returns the forced model name, when set.
func (o Options) hostModel() string {
	if o.HostModel != "" {
		return o.HostModel
	}
	return os.Getenv("DEVZONE_HOST_MODEL")
}

// trimSlash removes trailing slashes from an address.
func trimSlash(s string) string {
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}
