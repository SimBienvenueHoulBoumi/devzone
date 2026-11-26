package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// runStateCatalogSync appends missing <app>=off lines for catalog apps, holding
// the same lock as shell state functions to avoid lost concurrent writes.
func runStateCatalogSync(ctx *cli.Context, st *state.State) int {
	if _, err := os.Stat(st.Path()); err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	apps, err := catalogApps(codeRoot())
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	// Use replace through a temp file under lock by building the merged content
	// in Go but persisting with the State lock/write primitives: read under Set
	// serialization is not enough, so we take a lock by doing a no-op guarded
	// replace of the same content merged with additions.
	data, err := os.ReadFile(st.Path())
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	header := "# Catalog applications: set to on to install (devzone catalog)"
	missing := missingCatalogLines(string(data), apps)
	if len(missing) == 0 {
		return 0
	}
	var b strings.Builder
	b.Write(data)
	if len(data) > 0 && data[len(data)-1] != '\n' {
		b.WriteByte('\n')
	}
	if !strings.Contains(string(data), header) {
		b.WriteString(header)
		b.WriteByte('\n')
	}
	for _, line := range missing {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	tmp, err := os.CreateTemp(st.Dir(), ".devzone.catalog.*")
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.WriteString(b.String()); err != nil {
		tmp.Close()
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	if err := tmp.Close(); err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	if err := st.Replace(name); err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	return 0
}

// catalogApps returns sorted app names that have an app.conf in the catalog dir.
func catalogApps(code string) ([]string, error) {
	dir := os.Getenv("DEVZONE_CATALOG")
	if dir == "" {
		dir = filepath.Join(code, "catalog")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var apps []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, e.Name(), "app.conf")); err == nil {
			apps = append(apps, e.Name())
		}
	}
	sort.Strings(apps)
	return apps, nil
}

// missingCatalogLines returns <app>=off lines for apps absent from state content.
func missingCatalogLines(content string, apps []string) []string {
	var out []string
	for _, app := range apps {
		if hasStateKey(content, app) {
			continue
		}
		out = append(out, app+"=off")
	}
	return out
}

// hasStateKey reports whether content contains a key= line.
func hasStateKey(content, key string) bool {
	prefix := key + "="
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, prefix) {
			return true
		}
	}
	return false
}
