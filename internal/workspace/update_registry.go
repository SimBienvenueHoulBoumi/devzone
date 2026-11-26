package workspace

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

// registryClient is the HTTP client of the registry check, with a bound so a
// request to an unreachable registry cannot hang the command.
var registryClient = &http.Client{Timeout: 10 * time.Second}

// RegistryImageExists tells whether the image of a release is published at the
// registry, as update_image_exists does: an anonymous pull token, then a HEAD
// on the manifest. A failing network counts as absent. The token is only sent
// in a request and is never printed.
func RegistryImageExists(tag string) bool {
	path := strings.TrimPrefix(imageRepo, "ghcr.io/")
	tokenURL := "https://ghcr.io/token?scope=repository:" + path + ":pull"
	response, err := registryClient.Get(tokenURL)
	if err != nil {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	_ = response.Body.Close()
	if err != nil || response.StatusCode != http.StatusOK {
		return false
	}
	var tokenReply struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &tokenReply); err != nil || tokenReply.Token == "" {
		return false
	}
	request, err := http.NewRequest(http.MethodHead, "https://ghcr.io/v2/"+path+"/manifests/"+tag, nil)
	if err != nil {
		return false
	}
	request.Header.Set("Authorization", "Bearer "+tokenReply.Token)
	request.Header.Set("Accept", "application/vnd.oci.image.index.v1+json,application/vnd.\x64ocker.distribution.manifest.list.v2+json")
	response, err = registryClient.Do(request)
	if err != nil {
		return false
	}
	_ = response.Body.Close()
	return response.StatusCode >= 200 && response.StatusCode < 300
}
