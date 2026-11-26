package gitlab

import (
	"os"
	"strings"
	"testing"
)

// TestHostSetSetsOnce checks that host-set sets the line once and keeps
// the localhost line (gitlab.bats "host-set sets gitlab.localhost once").
func TestHostSetSetsOnce(t *testing.T) {
	f := newFixture(t)
	f.writeFile("hosts", "127.0.0.1 localhost\n")
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	data := f.readFile("hosts")
	if strings.Count(data, "devzone:gitlab") != 1 {
		t.Fatalf("hosts = %q", data)
	}
	if !strings.Contains(data, "127.0.0.1 localhost") {
		t.Fatalf("hosts = %q", data)
	}
	if !strings.Contains(data, "127.0.0.1\tgitlab.localhost # devzone:gitlab") {
		t.Fatalf("hosts = %q", data)
	}
}

// TestHostSetReplacesMarked checks the replacement of a line already marked
// with another address (gitlab.bats "host-set replaces an IPv6 line").
func TestHostSetReplacesMarked(t *testing.T) {
	f := newFixture(t)
	f.writeFile("hosts", "127.0.0.1 localhost\nfdc4:f303:9324::254\tgitlab.localhost # devzone:gitlab\n")
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	data := f.readFile("hosts")
	if strings.Count(data, "devzone:gitlab") != 1 {
		t.Fatalf("hosts = %q", data)
	}
	if strings.Contains(data, "fdc4") {
		t.Fatalf("hosts = %q", data)
	}
	if !strings.Contains(data, "127.0.0.1\tgitlab.localhost # devzone:gitlab") {
		t.Fatalf("hosts = %q", data)
	}
}

// TestHostSetWithoutRights checks the warning and code 0 without rights nor
// usable sudo (gitlab.bats "host-set without rights nor usable sudo").
func TestHostSetWithoutRights(t *testing.T) {
	f := newFixture(t)
	hosts := f.root + "/hosts"
	f.writeFile("hosts", "127.0.0.1 localhost\n")
	_ = os.Chmod(hosts, 0o444)
	// A fake sudo that refuses, like the sudo fake of the bats test
	if err := os.WriteFile(f.root+"/bin/sudo", []byte("#!/usr/bin/env bash\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(f.errStr(), "gitlab.localhost name not set") {
		t.Fatalf("stderr = %q", f.errStr())
	}
	if strings.Contains(f.readFile("hosts"), "devzone:gitlab") {
		t.Fatalf("hosts = %q", f.readFile("hosts"))
	}
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("second run code = %d", code)
	}
	if !strings.Contains(f.errStr(), "gitlab.localhost name not set") {
		t.Fatalf("stderr = %q", f.errStr())
	}
}

// TestHostRemove checks the removal of the line and the unchanged file without
// a line (gitlab.bats "host-remove removes the line, keeps localhost").
func TestHostRemove(t *testing.T) {
	f := newFixture(t)
	f.writeFile("hosts", "127.0.0.1 localhost\n")
	if code := f.run("host-set"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if code := f.run("host-remove"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	data := f.readFile("hosts")
	if strings.Contains(data, "devzone:gitlab") {
		t.Fatalf("hosts = %q", data)
	}
	if !strings.Contains(data, "127.0.0.1 localhost") {
		t.Fatalf("hosts = %q", data)
	}
	before := f.readFile("hosts")
	if code := f.run("host-remove"); code != 0 {
		t.Fatalf("second run code = %d", code)
	}
	if f.readFile("hosts") != before {
		t.Fatalf("hosts changed without a line")
	}
}
