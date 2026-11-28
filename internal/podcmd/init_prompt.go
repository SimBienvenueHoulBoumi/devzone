package podcmd

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// promptStart and promptEnd delimit the block written to .bashrc by the pod.
const (
	promptStart = "# >>> devzone prompt >>>"
	promptEnd   = "# <<< devzone prompt <<<"
)

// promptBlock is the exact shell block installed in the pod's .bashrc.
const promptBlock = `# >>> devzone prompt >>>
# Interactive shells in the pod must not write core files either (#961).
ulimit -c 0 2>/dev/null || true
PS1='$(devzone kube prompt) '"$PS1"
# <<< devzone prompt <<<
`

// legacyPromptTokens identify lines of prompt blocks written before the Go
// kube prompt replaced the shell libraries that no longer exist.
var legacyPromptTokens = []string{
	"invite-kube.sh",
	"kube-prompt.sh",
	"devzone_invite_kube",
	"devzone_kube_prompt",
}

// initPrompt migrates a stale prompt block, then installs the current block
// once; a missing or unwritable .bashrc is logged without stopping startup.
func initPrompt(ctx *cli.Context) bool {
	bashrc := filepath.Join(os.Getenv("HOME"), ".bashrc")
	data, err := os.ReadFile(bashrc)
	if err != nil && !os.IsNotExist(err) {
		logInit(ctx, "prompt: cannot write "+bashrc)
		return false
	}
	content := string(data)
	if needsPromptMigration(content) {
		if err := os.WriteFile(bashrc, []byte(removePromptLines(content)), 0o644); err != nil {
			logInit(ctx, "prompt: cannot write "+bashrc)
			return false
		}
		logInit(ctx, "prompt block migrated to the Go command")
	} else if strings.Contains(content, promptStart) {
		logInit(ctx, "prompt block already present")
		return true
	}
	file, err := os.OpenFile(bashrc, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		logInit(ctx, "prompt: cannot write "+bashrc)
		return false
	}
	if _, err := file.WriteString(promptBlock); err != nil {
		_ = file.Close()
		logInit(ctx, "prompt: cannot write "+bashrc)
		return false
	}
	if err := file.Close(); err != nil {
		logInit(ctx, "prompt: cannot write "+bashrc)
		return false
	}
	logInit(ctx, "prompt block added to "+bashrc)
	return true
}

// needsPromptMigration reports whether the file has old prompt symbols, a
// different block under the current markers, or a dangling end marker.
func needsPromptMigration(content string) bool {
	for _, token := range legacyPromptTokens {
		if strings.Contains(content, token) {
			return true
		}
	}
	if strings.Contains(content, promptStart) && !strings.Contains(content, promptBlock) {
		return true
	}
	return strings.Contains(content, promptEnd) && !strings.Contains(content, promptStart)
}

// removePromptLines drops the old prompt symbols and both marker lines while
// keeping the rest of the user's .bashrc.
func removePromptLines(content string) string {
	kept := make([]string, 0, strings.Count(content, "\n")+1)
	for _, line := range strings.Split(content, "\n") {
		if containsAny(line, legacyPromptTokens) || containsAny(line, []string{promptStart, promptEnd}) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// containsAny reports whether text contains one of the given tokens.
func containsAny(text string, tokens []string) bool {
	for _, token := range tokens {
		if strings.Contains(text, token) {
			return true
		}
	}
	return false
}
