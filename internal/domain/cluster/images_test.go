package cluster

import "testing"

// TestChooseImagePreference checks the order of the images with a shell.
func TestChooseImagePreference(t *testing.T) {
	names := []string{
		"registry.k8s.io/pause:3.9",
		"docker.io/library/alpine:3.20",
		"docker.io/library/postgres:16",
		"registry.k8s.io/kube-proxy:v1.30.0",
	}
	if got := chooseImage(names); got != "docker.io/library/postgres:16" {
		t.Fatalf("chooseImage = %q, want postgres", got)
	}
}

// TestChooseImageOrder checks that the preference list wins over the node order.
func TestChooseImageOrder(t *testing.T) {
	names := []string{"ubuntu:22.04", "busybox:1.36", "devzone-workspace:latest"}
	if got := chooseImage(names); got != "devzone-workspace:latest" {
		t.Fatalf("chooseImage = %q, want devzone-workspace", got)
	}
}

// TestChooseImageDigests checks that tags and digests do not hide a usable image.
func TestChooseImageDigests(t *testing.T) {
	for _, name := range []string{
		"ghcr.io/devzone/debian@sha256:abcdef", "docker.io/library/busybox:1.36",
	} {
		if got := chooseImage([]string{name}); got != name {
			t.Fatalf("chooseImage(%q) = %q, want the image itself", name, got)
		}
	}
}

// TestChooseImageForbidden checks that system images are never selected.
func TestChooseImageForbidden(t *testing.T) {
	for _, name := range []string{
		"registry.k8s.io/pause:3.9", "kube-apiserver:v1.30.0", "etcd:3.5",
		"coredns:1.11", "kindnetd:latest", "local-path-helper:v0.0.29",
	} {
		if got := chooseImage([]string{name}); got != "" {
			t.Fatalf("chooseImage(%q) = %q, want none", name, got)
		}
	}
}
