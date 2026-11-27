package workspace

import (
	"fmt"
	"os"
	"unicode/utf16"
)

// portsTaskRestartInterval is the wait before Task Scheduler relaunches the
// watcher after a failed run, as an ISO 8601 duration. One minute is the
// smallest value the scheduler accepts.
const portsTaskRestartInterval = "PT1M"

// portsTaskRestartCount is the largest number of relaunches the scheduler
// accepts. It plays the part of KeepAlive on macOS and Restart=on-failure on
// Linux, which have no limit: a watcher that keeps failing is retried every
// minute, a watcher stopped on purpose is not failing and stays stopped.
const portsTaskRestartCount = 999

// portsTaskUser returns the account the task runs as: DOMAIN\user, or the user
// name alone when no domain is set. The task runs with the rights of the user
// who opened the session, never as an administrator, so installing it needs no
// elevation.
func portsTaskUser() string {
	name := os.Getenv("USERNAME")
	if domain := os.Getenv("USERDOMAIN"); domain != "" && name != "" {
		return domain + `\` + name
	}
	return name
}

// portsAgentTaskText returns the scheduled task of the watcher, in the XML
// schema that schtasks /Create /XML reads. The task starts at the logon of the
// user and runs the watcher in the devzone folder. PT0S disables the time limit
// the scheduler sets by default (72 hours), which would stop a watcher that is
// meant to run for the whole session. Task Scheduler has no environment block:
// the watcher gets the environment of the session, so the PATH and KUBECONFIG
// written for the launch agent of macOS and the user unit of Linux do not apply.
func portsAgentTaskText(watcher, folder string) string {
	user := xmlEscape(portsTaskUser())
	return `<?xml version="1.0" encoding="UTF-16"?>` + "\n" +
		`<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">` + "\n" +
		"  <RegistrationInfo>\n    <Description>devzone port watcher</Description>\n  </RegistrationInfo>\n" +
		"  <Triggers>\n    <LogonTrigger>\n      <Enabled>true</Enabled>\n" +
		"      <UserId>" + user + "</UserId>\n    </LogonTrigger>\n  </Triggers>\n" +
		"  <Principals>\n    <Principal id=\"Author\">\n      <UserId>" + user + "</UserId>\n" +
		"      <LogonType>InteractiveToken</LogonType>\n      <RunLevel>LeastPrivilege</RunLevel>\n" +
		"    </Principal>\n  </Principals>\n" +
		"  <Settings>\n" +
		"    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n" +
		"    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n" +
		"    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n" +
		"    <AllowHardTerminate>true</AllowHardTerminate>\n" +
		"    <StartWhenAvailable>true</StartWhenAvailable>\n" +
		"    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>\n" +
		"    <AllowStartOnDemand>true</AllowStartOnDemand>\n" +
		"    <Enabled>true</Enabled>\n" +
		"    <Hidden>true</Hidden>\n" +
		"    <RunOnlyIfIdle>false</RunOnlyIfIdle>\n" +
		"    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\n" +
		fmt.Sprintf("    <RestartOnFailure>\n      <Interval>%s</Interval>\n      <Count>%d</Count>\n    </RestartOnFailure>\n",
			portsTaskRestartInterval, portsTaskRestartCount) +
		"  </Settings>\n" +
		"  <Actions Context=\"Author\">\n    <Exec>\n" +
		"      <Command>" + xmlEscape(watcher) + "</Command>\n" +
		"      <Arguments>workspace ports agent</Arguments>\n" +
		"      <WorkingDirectory>" + xmlEscape(folder) + "</WorkingDirectory>\n" +
		"    </Exec>\n  </Actions>\n" +
		"</Task>\n"
}

// portsUTF16 encodes text as UTF-16 little endian behind a byte order mark, the
// encoding named by the XML declaration of the task. Why: the task file may
// hold accented user names and folders, which a plain ASCII-only reading of the
// file would not preserve; the declaration and the bytes must agree.
func portsUTF16(text string) []byte {
	units := utf16.Encode([]rune("\ufeff" + text))
	data := make([]byte, 0, 2*len(units))
	for _, unit := range units {
		data = append(data, byte(unit), byte(unit>>8))
	}
	return data
}
