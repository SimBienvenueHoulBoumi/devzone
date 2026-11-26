package workspace

import (
	"os/exec"
	"regexp"
	"strings"
)

// registryTokenPattern reads the anonymous pull token from the registry
// answer, as the sed expression of update_image_exists does.
var registryTokenPattern = regexp.MustCompile(`"token" *: *"([^"]*)"`)

// RegistryImageExists tells whether the image of a release is published at the
// registry, as update_image_exists does: an anonymous pull token is asked with
// curl, then a HEAD on the manifest. A failing network counts as absent. The
// token is only passed as an argument of a child process and is never printed.
// curl is used rather than a Go HTTP client so that the workstation binary
// keeps the same small dependency set as the shell command.
func RegistryImageExists(tag string) bool {
	path := strings.TrimPrefix(imageRepo, "ghcr.io/")
	answer, err := exec.Command("curl", "-fsS", "https://ghcr.io/token?scope=repository:"+path+":pull").Output()
	if err != nil {
		return false
	}
	match := registryTokenPattern.FindSubmatch(answer)
	if len(match) != 2 || len(match[1]) == 0 {
		return false
	}
	command := exec.Command("curl", "-fsSI",
		"-H", "Authorization: Bearer "+string(match[1]),
		"-H", "Accept: application/vnd.oci.image.index.v1+json,application/vnd.\x64ocker.distribution.manifest.list.v2+json",
		"https://ghcr.io/v2/"+path+"/manifests/"+tag)
	return command.Run() == nil
}
