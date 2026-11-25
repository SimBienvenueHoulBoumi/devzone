package cluster

import "strings"

// preferredImages lists the images with a shell, in the order they are chosen.
var preferredImages = []string{
	"devzone-workspace", "postgres", "alpine", "busybox", "ubuntu", "debian",
}

// forbiddenImages lists the images that are never used for a debug pod.
var forbiddenImages = []string{
	"pause", "etcd", "coredns", "kindnetd", "local-path-helper",
}

// chooseImage returns the most preferred usable image of a node, or an empty
// string when none of its images has a shell.
func chooseImage(names []string) string {
	for _, wanted := range preferredImages {
		for _, name := range names {
			if imageBase(name) == wanted {
				return name
			}
		}
	}
	return ""
}

// imageBase removes the registry, the tag and the digest of an image name, and
// returns an empty string for system images or names without a usable base.
func imageBase(name string) string {
	base := strings.SplitN(name, "@", 2)[0]
	if i := strings.LastIndexByte(base, '/'); i >= 0 {
		base = base[i+1:]
	}
	if i := strings.IndexByte(base, ':'); i >= 0 {
		base = base[:i]
	}
	if base == "" || strings.HasPrefix(base, "kube-") {
		return ""
	}
	for _, forbidden := range forbiddenImages {
		if base == forbidden {
			return ""
		}
	}
	return base
}
