package packages

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

// Refusal is a command error whose message is shown to the user.
type Refusal struct {
	Message string
}

// Error implements error.
func (r *Refusal) Error() string { return r.Message }

// refuse builds a user-facing command error.
func refuse(format string, args ...any) error {
	return &Refusal{Message: fmt.Sprintf(format, args...)}
}

// Env carries the paths, the injected installer and the output streams of a
// packages command.
type Env struct {
	List      string
	Marker    string
	Updated   string
	Installer Installer
	Now       func() time.Time
	Out       io.Writer
	Err       io.Writer
}

// now returns the injected clock, defaulting to the system clock.
func (e *Env) now() time.Time {
	if e.Now == nil {
		return time.Now()
	}
	return e.Now()
}

// Show prints the packages of the list with their installation state.
func (e *Env) Show() error {
	names := readNames(e.List)
	if len(names) == 0 {
		fmt.Fprintln(e.Out, "no package (devzone packages add <name>)")
		return nil
	}
	for _, name := range names {
		mark := "○"
		if e.Installer.Installed(name) {
			mark = "✔"
		}
		fmt.Fprintf(e.Out, "  %s %s\n", mark, name)
	}
	return nil
}

// updateIndex refreshes the index at most once per hour, as the shell did.
func (e *Env) updateIndex() error {
	data, err := os.ReadFile(e.Updated)
	last := 0
	if err == nil {
		last, _ = strconv.Atoi(strings.TrimSpace(string(data)))
	}
	if last > 0 && e.now().Unix()-int64(last) < 3600 {
		return nil
	}
	if err := e.Installer.Update(); err != nil {
		return err
	}
	return os.WriteFile(e.Updated, []byte(strconv.FormatInt(e.now().Unix(), 10)+"\n"), 0o644)
}

// warnIndex prints the non-fatal warning of a stale index.
func (e *Env) warnIndex() {
	if err := e.updateIndex(); err != nil && e.Err != nil {
		fmt.Fprintln(e.Err, "apt index not updated")
	}
}

// Add validates, installs and records one or more packages.
func (e *Env) Add(args []string) error {
	for _, name := range args {
		if strings.HasPrefix(name, "-") {
			return refuse("unknown argument: %s (devzone packages add <name>…)", name)
		}
	}
	if len(args) == 0 {
		return refuse("add expects at least one name: devzone packages add <name>…")
	}
	e.warnIndex()
	for _, name := range args {
		if !e.Installer.Available(name) {
			return refuse("unknown package: %s (list unchanged)", name)
		}
	}
	already := map[string]bool{}
	for _, name := range args {
		already[name] = e.Installer.Installed(name)
	}
	if err := e.Installer.Install(args); err != nil {
		return refuse("installation failed: %s (list unchanged)", strings.Join(args, " "))
	}
	lines := readLines(e.List)
	listed := map[string]bool{}
	for _, line := range lines {
		listed[nameOf(line)] = true
	}
	for _, name := range args {
		if listed[name] {
			continue
		}
		if already[name] {
			lines = append(lines, name+" "+presentMark)
			fmt.Fprintf(e.Out, "%s : already present before devzone packages (marked ; removing will leave it installed)\n", name)
		} else {
			lines = append(lines, name)
		}
	}
	return writeList(e.List, lines)
}

// Remove drops packages from the list and uninstalls the ones not provided by
// the image.
func (e *Env) Remove(args []string) error {
	for _, name := range args {
		if strings.HasPrefix(name, "-") {
			return refuse("unknown argument: %s (devzone packages remove <name>…)", name)
		}
	}
	if len(args) == 0 {
		return refuse("remove expects at least one name: devzone packages remove <name>…")
	}
	lines := readLines(e.List)
	names := readNames(e.List)
	removals := []string{}
	for _, name := range args {
		if !containsName(names, name) {
			return refuse("package not listed: %s (provided by the image?) : devzone packages remove does not add image packages", name)
		}
		if !isMarkedPresent(lines, name) {
			removals = append(removals, name)
		}
	}
	if len(removals) > 0 {
		if err := e.Installer.Remove(removals); err != nil {
			return refuse("removal failed: %s (list unchanged)", strings.Join(removals, " "))
		}
	}
	for _, name := range args {
		if isMarkedPresent(lines, name) {
			fmt.Fprintf(e.Out, "%s : removed from the list, left installed (present before devzone packages)\n", name)
		}
	}
	remaining := []string{}
	for _, line := range lines {
		if !containsName(args, nameOf(line)) {
			remaining = append(remaining, line)
		}
	}
	return writeList(e.List, remaining)
}

// Apply installs the missing packages after a rebuild and records the ones
// still missing in the failure marker.
func (e *Env) Apply() error {
	missing := []string{}
	for _, name := range readNames(e.List) {
		if !e.Installer.Installed(name) {
			missing = append(missing, name)
		}
	}
	if len(missing) == 0 {
		return e.clearMarker()
	}
	e.warnIndex()
	for _, name := range missing {
		_ = e.Installer.Install([]string{name})
	}
	still := []string{}
	for _, name := range missing {
		if !e.Installer.Installed(name) {
			still = append(still, name)
		}
	}
	if len(still) > 0 {
		if err := os.WriteFile(e.Marker, []byte(strings.Join(still, "\n")+"\n"), 0o644); err != nil {
			return refuse("marker not written: %v", err)
		}
		return &Refusal{}
	}
	return e.clearMarker()
}

// clearMarker removes the failure marker when every package is installed.
func (e *Env) clearMarker() error {
	if e.Marker == "" {
		return nil
	}
	if err := os.Remove(e.Marker); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
