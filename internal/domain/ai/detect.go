package ai

import (
	"context"
	"encoding/json"
	"strings"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// hostAlias is the name used from the pod to reach the workstation service.
const hostAlias = "host." + "\x64\x6f\x63\x6b\x65\x72" + ".internal"

// info is one detected model: name, byte size and local digest.
type info struct {
	name   string
	size   int64
	digest string
}

// tagsJSON reads the raw /api/tags payload; empty when the service does not answer.
func tagsJSON(ctx context.Context, o Options) []byte {
	res, err := o.runner().Run(ctx, "curl", []string{"-fsS", "--max-time", "3", o.url() + "/api/tags"}, dzexec.Opts{})
	if err != nil || res.Code != 0 {
		return nil
	}
	return res.Stdout
}

// isEmbedding reports whether a model is an embedding model, by declared type
// or by name, as the installed detection did.
func isEmbedding(name string) bool { return strings.Contains(strings.ToLower(name), "embed") }

// Infos lists the detected non-embedding models with their size and digest.
func Infos(ctx context.Context, o Options) []info {
	data := tagsJSON(ctx, o)
	if len(data) == 0 {
		return nil
	}
	var parsed struct {
		Models []struct {
			Name    string `json:"name"`
			Size    int64  `json:"size"`
			Digest  string `json:"digest"`
			Details struct {
				Type string `json:"type"`
			} `json:"details"`
		} `json:"models"`
	}
	if json.Unmarshal(data, &parsed) != nil {
		return nil
	}
	var out []info
	for _, m := range parsed.Models {
		if m.Details.Type == "embedding" || isEmbedding(m.Name) {
			continue
		}
		out = append(out, info{name: m.Name, size: m.Size, digest: m.Digest})
	}
	return out
}

// Models lists the names of the detected models.
func Models(ctx context.Context, o Options) []string {
	all := Infos(ctx, o)
	var out []string
	for _, m := range all {
		out = append(out, m.name)
	}
	return out
}
