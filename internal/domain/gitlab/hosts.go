package gitlab

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// hostMark marks the line of gitlab.localhost of the hosts file.
const hostMark = "# devzone:gitlab"

// hostsFile returns the file of the hosts of the module: DEVZONE_HOSTS for
// the tests, never the real /etc/hosts of the machine (HOSTS of gitlab.sh).
func (r *run) hostsFile() string {
	if hosts := os.Getenv("DEVZONE_HOSTS"); hosts != "" {
		return hosts
	}
	return "/etc/hosts"
}

// hostLine is the line set in the hosts file by hostSet.
func hostLine() string {
	return "127.0.0.1\tgitlab.localhost " + hostMark
}

// countMarked returns the number of lines of text holding the mark, like
// `grep -c "$GITLAB_HOST_MARK"`.
func countMarked(text string) int {
	n := 0
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, hostMark) {
			n++
		}
	}
	return n
}

// hasExactLine reports whether text holds exactly the line wanted, like
// `grep -qxF`.
func hasExactLine(text, line string) bool {
	for _, l := range strings.Split(text, "\n") {
		if l == line {
			return true
		}
	}
	return false
}

// removeMarked returns text without the lines holding the mark, like
// `grep -v "$GITLAB_HOST_MARK"` (no trailing newline added).
func removeMarked(text string) string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if !strings.Contains(line, hostMark) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// writable reports whether the file is writable by this user.
func writable(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Mode().IsRegular() && info.Mode().Perm()&0o200 != 0
}

// writeHosts writes text into the hosts file; when it cannot, it warns like
// gitlab_host_set (the line may be refused, sudo may be absent or refused).
func (r *run) writeHosts(path, text string) {
	if writable(path) {
		_ = os.WriteFile(path, []byte(text), 0o644)
		return
	}
	fmt.Fprintf(r.errOut(), "devzone : gitlab : gitlab.localhost name not set in %s (sudo -n unavailable or refused)\n", path)
}

// sudoWriteHosts tries sudo -n tee, as gitlab_host_set does; false when refused.
func sudoWriteHosts(path, text string) bool {
	cmd := exec.Command("sudo", "-n", "tee", "-a", path)
	cmd.Stdin = strings.NewReader(text)
	err := cmd.Run()
	return err == nil
}

// hostSet sets the line of gitlab.localhost in the hosts file
// (gitlab.sh gitlab_host_set): idempotent; a failure never fails the run
// (a warning on stderr, code 0) so the installation does not fail.
func (r *run) hostSet() int {
	path := r.hostsFile()
	line := hostLine()
	data, _ := os.ReadFile(path)
	text := string(data)
	if countMarked(text) == 1 && hasExactLine(text, line) {
		return 0
	}
	if countMarked(text) > 0 {
		r.writeHosts(path, removeMarked(text)+line+"\n")
		return 0
	}
	if writable(path) {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintf(r.errOut(), "devzone : gitlab : gitlab.localhost name not set in %s (insufficient write rights)\n", path)
			return 0
		}
		_, _ = f.WriteString(line + "\n")
		_ = f.Close()
		return 0
	}
	if !sudoWriteHosts(path, line+"\n") {
		fmt.Fprintf(r.errOut(), "devzone : gitlab : gitlab.localhost name not set in %s (sudo -n unavailable or refused)\n", path)
	}
	return 0
}

// hostRemove removes the marked line of the hosts file
// (gitlab.sh gitlab_host_remove): nothing without a line, code 0.
func (r *run) hostRemove() int {
	path := r.hostsFile()
	data, _ := os.ReadFile(path)
	text := string(data)
	if countMarked(text) == 0 {
		return 0
	}
	r.writeHosts(path, removeMarked(text))
	return 0
}
