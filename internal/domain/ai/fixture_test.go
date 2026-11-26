package ai

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// fixture is a hermetic AI command environment with a fake runner.
type fixture struct {
	o   Options
	r   *fake.Runner
	out *bytes.Buffer
	err *bytes.Buffer
}

// newFixture creates a disposable home and a fake program for curl.
func newFixture(t *testing.T) fixture {
	t.Helper()
	r := fake.New()
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	return fixture{
		o: Options{
			Runner:   r,
			Out:      out,
			Err:      errOut,
			Home:     t.TempDir(),
			URL:      "http://127.0.0.1:9",
			Registry: "http://registre.faux",
		},
		r: r, out: out, err: errOut,
	}
}

// tags sets the fake /api/tags answer.
func (f fixture) tags(payload string) {
	f.r.On("curl", []string{"-fsS", "--max-time", "3", f.o.url() + "/api/tags"},
		dzexec.Result{Stdout: []byte(payload)})
}

// manifest sets the fake registry answer of one model and returns its digest.
func (f fixture) manifest(name, body string, code int) string {
	short, tag := name, "latest"
	if i := strings.LastIndex(name, ":"); i >= 0 {
		short, tag = name[:i], name[i+1:]
	}
	url := f.o.registryURL() + "/v2/library/" + short + "/manifests/" + tag
	f.r.On("curl", []string{"-fsS", "--max-time", "5", "-H", "Accept: " + manifestType, url},
		dzexec.Result{Stdout: []byte(body), Code: code})
	return digest(body)
}

// digest is the lowercase sha256 of a manifest body.
func digest(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// ctx is the background context of the tests.
func ctx() context.Context { return context.Background() }
