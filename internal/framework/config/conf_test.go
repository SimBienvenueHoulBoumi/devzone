package config

import (
	"os"
	"testing"
)

func testFilePath(t *testing.T, name, root string, want string) {
	tmp := t.TempDir()
	if root != "" {
		os.Setenv("DEVZONE_ROOT", root)
		defer os.Unsetenv("DEVZONE_ROOT")
	}
	_ = tmp
	_ = name
}

func TestGetKeyInSectionDefault(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty, got %q", expected)
	}
}

func TestGetKeyInSectionMissingFile(t *testing.T) {
	path := t.TempDir() + "/nonexistent/.argocd.conf"
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty, got %q", expected)
	}
}

func TestGetKeyInSectionMissingSection(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[other]\nkey = value\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty, got %q", expected)
	}
}

func TestGetKeyInSectionMissingKey(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\notherkey = value\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty, got %q", expected)
	}
}

func TestGetKeyInSectionEmptyValue(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = \n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty, got %q", expected)
	}
}

func TestGetKeyInSectionInvalidSpace(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = hello world\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty for space, got %q", expected)
	}
}

func TestGetKeyInSectionInvalidDash(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = -x\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "" {
		t.Fatalf("expected empty for '-', got %q", expected)
	}
}

func TestGetKeyInSectionValidValue(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = devzone\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "devzone" {
		t.Fatalf("expected devzone, got %q", expected)
	}
}

func TestGetKeyInSectionAnotherContext(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = autre\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "autre" {
		t.Fatalf("expected autre, got %q", expected)
	}
}

func TestGetKeyInSectionWithComment(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("# comment\n[cluster]\ncontext = devzone\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "devzone" {
		t.Fatalf("expected devzone, got %q", expected)
	}
}

func TestGetKeyInSectionWithCommentAfterValue(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = devzone # comment\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "devzone" {
		t.Fatalf("expected devzone, got %q", expected)
	}
}

func TestGetKeyInSectionIndentedKeyValue(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\n    context = devzone\n"), 0o644)
	expected := GetKeyInSection(path, "cluster", "context")
	if expected != "devzone" {
		t.Fatalf("expected devzone, got %q", expected)
	}
}
