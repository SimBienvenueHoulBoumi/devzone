package argocd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRenderApplicationGolden checks the one-source and two-source manifests
// against committed fixtures, including parameter precedence in both shapes.
func TestRenderApplicationGolden(t *testing.T) {
	params := []string{"image.tag=1.2.3", "networkPolicy.restrictEgress=true"}
	for _, tc := range []struct {
		name       string
		file       string
		valuesRepo string
	}{
		{"single source", "application_single_source.yaml", ""},
		{"two sources", "application_two_sources.yaml", "https://github.com/acme/devzone-argocd.git"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var b bytes.Buffer
			err := RenderApplication(&b, workspaceAppName, "workspace", "devzone-workspace",
				"https://github.com/acme/devzone.git", "v1.2.3", "charts/devzone-workspace",
				params, tc.valuesRepo)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(filepath.Join("testdata", tc.file))
			if err != nil {
				t.Fatal(err)
			}
			if b.String() != string(want) {
				t.Fatalf("manifest differs from %s:\ngot:\n%s\nwant:\n%s", tc.file, b.String(), want)
			}
			if tc.valuesRepo != "" && strings.Contains(b.String(), "\n  source:\n") {
				t.Fatalf("singular spec.source in a two-source manifest:\n%s", b.String())
			}
		})
	}
}
