package workspace

import (
	"strings"
	"testing"
	"unicode/utf16"
)

// decodeTaskFile returns the text of a task file written in UTF-16 with its
// byte order mark, as portsUTF16 writes it. A file without the mark fails the
// test, since schtasks would read it with another encoding than the declaration.
func decodeTaskFile(t *testing.T, data []byte) string {
	t.Helper()
	if len(data) < 2 || data[0] != 0xFF || data[1] != 0xFE {
		t.Fatalf("no UTF-16 little endian byte order mark in % x", data[:2])
	}
	units := make([]uint16, 0, len(data)/2)
	for i := 2; i+1 < len(data); i += 2 {
		units = append(units, uint16(data[i])|uint16(data[i+1])<<8)
	}
	return strings.TrimPrefix(string(utf16.Decode(units)), "\ufeff")
}

// TestPortsTaskTextRunsAtLogon checks the settings the watcher needs from its
// task: it starts at the logon of the user, as that user and never as an
// administrator, without a time limit, and is relaunched after a failed run.
// The check is textual because the XML is only read by schtasks on Windows.
func TestPortsTaskTextRunsAtLogon(t *testing.T) {
	t.Setenv("USERDOMAIN", "CORP")
	t.Setenv("USERNAME", "sim")
	text := portsAgentTaskText(`C:\cache\devzone.exe`, `C:\Dev Zone`)
	for _, want := range []string{
		"<LogonTrigger>", "<UserId>CORP\\sim</UserId>",
		"<LogonType>InteractiveToken</LogonType>", "<RunLevel>LeastPrivilege</RunLevel>",
		"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>",
		"<Interval>PT1M</Interval>", "<Count>999</Count>",
		"<Command>C:\\cache\\devzone.exe</Command>",
		"<Arguments>workspace ports agent</Arguments>",
		"<WorkingDirectory>C:\\Dev Zone</WorkingDirectory>",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("the task misses %q:\n%s", want, text)
		}
	}
}

// TestPortsTaskTextEscapesPaths checks that a folder with XML characters cannot
// break the document: an unescaped ampersand or angle bracket would make the
// task file invalid, and schtasks would refuse it.
func TestPortsTaskTextEscapesPaths(t *testing.T) {
	text := portsAgentTaskText(`C:\a&b\devzone.exe`, `C:\<x>`)
	if !strings.Contains(text, "<Command>C:\\a&amp;b\\devzone.exe</Command>") {
		t.Fatalf("the command is not escaped:\n%s", text)
	}
	if !strings.Contains(text, "<WorkingDirectory>C:\\&lt;x&gt;</WorkingDirectory>") {
		t.Fatalf("the folder is not escaped:\n%s", text)
	}
}

// TestPortsTaskUser checks the account of the task: DOMAIN\user when the domain
// is known, the user name alone otherwise, and nothing when no user is set.
func TestPortsTaskUser(t *testing.T) {
	t.Setenv("USERDOMAIN", "")
	t.Setenv("USERNAME", "sim")
	if got := portsTaskUser(); got != "sim" {
		t.Fatalf("user without domain = %q", got)
	}
	t.Setenv("USERDOMAIN", "CORP")
	if got := portsTaskUser(); got != `CORP\sim` {
		t.Fatalf("user with domain = %q", got)
	}
}

// TestPortsUTF16RoundTrip checks that the task file decodes to the text it was
// built from, accents included, behind a little endian byte order mark.
func TestPortsUTF16RoundTrip(t *testing.T) {
	text := "<Task>Dev Zone é</Task>\n"
	if got := decodeTaskFile(t, portsUTF16(text)); got != text {
		t.Fatalf("round trip = %q, want %q", got, text)
	}
}
