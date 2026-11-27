package podcmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// imageProgram is the devzone binary shipped in the workspace image. It is
// built from components so this file stays portable to other operating systems.
func imageProgram() string {
	return filepath.Join(string(filepath.Separator), "usr", "local", "bin", "devzone")
}

// statusLookPath resolves name against an explicit PATH value, so the summary
// can be tested without changing the PATH of the test process.
type statusLookPath func(pathValue, name string) (string, error)

// lookPathInValue returns the first file named name in the directories of
// pathValue, or an error when no directory holds it.
func lookPathInValue(pathValue, name string) (string, error) {
	for _, dir := range filepath.SplitList(pathValue) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, name)
		info, err := os.Stat(candidate)
		if err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", os.ErrNotExist
}

// programLookPath is the resolver used by the status line; tests replace it
// and restore it, so no fake executable has to be placed in the real PATH.
var programLookPath statusLookPath = lookPathInValue

// shadowedProgramWarning returns the warning when the first devzone of
// pathValue is not the image program, and "" when it is, when no devzone is
// found, or when a path cannot be made absolute. The warning names the repair
// command because the pod PATH puts the npm bin before the image bin (#980).
func shadowedProgramWarning(pathValue string, look statusLookPath, image string) string {
	if look == nil {
		look = lookPathInValue
	}
	found, err := look(pathValue, "devzone")
	if err != nil {
		return ""
	}
	foundAbs, err := filepath.Abs(found)
	if err != nil {
		return ""
	}
	imageAbs, err := filepath.Abs(image)
	if err != nil {
		return ""
	}
	if filepath.Clean(foundAbs) == filepath.Clean(imageAbs) {
		return ""
	}
	return fmt.Sprintf("devzone in PATH is %s instead of the image program %s: npm uninstall -g devzone", found, image)
}

// printProgramLine warns when an npm copy hides the devzone program of the
// image, so the user knows which copy answers and how to remove it.
func printProgramLine(ctx *cli.Context) {
	if msg := shadowedProgramWarning(os.Getenv("PATH"), programLookPath, imageProgram()); msg != "" {
		fmt.Fprintf(ctx.Out, "  ⚠ program        %s\n", msg)
	}
}
