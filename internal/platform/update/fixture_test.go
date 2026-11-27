package update

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// fixture is a fake package and a devzone folder installed from a package. The
// commander records the commands the update would run instead of running them.
type fixture struct {
	t      *testing.T
	pkg    string // package root of the version the update installs
	folder string // devzone folder, installed from an older package
	out    bytes.Buffer
	errOut bytes.Buffer
	calls  []string
	answer string // what the user types at each question
	code   int    // exit status the fake commander gives
}

// write creates root/rel with content, creating its folders.
func write(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newPackage builds a fake package of the given version: its files carry mark, so
// a test can tell which version a file comes from.
func newPackage(t *testing.T, version, mark string) string {
	t.Helper()
	root := t.TempDir()
	write(t, root, "package.json", `{"name":"devzone","version":"`+version+`"}`+"\n")
	write(t, root, ".devcontainer/devcontainer.json", `{"marque":"`+mark+`"}`+"\n")
	write(t, root, ".devcontainer/devzone", "#!/usr/bin/env bash\necho "+mark+"\n")
	write(t, root, "Makefile", "# makefile "+mark+"\n")
	write(t, root, ".gitattributes", "*.sh text eol=lf\n")
	write(t, root, "README.md", "# devzone "+mark+"\n")
	write(t, root, "LICENSE", "licence "+mark+"\n")
	write(t, root, "manage/scripts/uninstall.sh", "#!/usr/bin/env bash\necho desinstaller-"+mark+"\n")
	return root
}

// newFixture installs a devzone folder from the package oldPkg, then sets up the
// update to next: the commander is the recorder of this fixture.
func newFixture(t *testing.T, oldPkg, next string) *fixture {
	t.Helper()
	f := &fixture{t: t, pkg: next, folder: filepath.Join(t.TempDir(), "devzone")}
	if err := os.MkdirAll(f.folder, 0o755); err != nil {
		t.Fatal(err)
	}
	install(t, oldPkg, f.folder)
	return f
}

// install makes folder a devzone of pkg, as a creation does: the package files are
// copied and the manifest is written with the version of the package.
func install(t *testing.T, pkg, folder string) {
	t.Helper()
	files, err := manifest.PackageFiles(pkg)
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range files {
		src := filepath.Join(pkg, filepath.FromSlash(rel))
		dst := filepath.Join(folder, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := copyFile(src, dst, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := manifest.Write(folder, PackageVersion(pkg), files); err != nil {
		t.Fatal(err)
	}
	// The creation writes the .gitignore too, outside the manifest
	if err := manifest.CompleteGitignore(folder); err != nil {
		t.Fatal(err)
	}
}

// run records one command of the fake commander and returns the fixture status.
func (f *fixture) run(dir string, out, errOut io.Writer, name string, args ...string) int {
	f.calls = append(f.calls, dir+"|"+name+" "+strings.Join(args, " "))
	return f.code
}

// options returns the update options of this fixture for the given answers.
func (f *fixture) options(assumeYes, noRebuild, terminal bool) Options {
	return Options{
		Folder:    f.folder,
		Package:   f.pkg,
		AssumeYes: assumeYes,
		NoRebuild: noRebuild,
		Terminal:  terminal,
		In:        bufio.NewReader(strings.NewReader(f.answer)),
		Out:       &f.out,
		Err:       &f.errOut,
		Now:       func() string { return "20990101-000000" },
		Run:       f.run,
	}
}

// backupDir is the backup folder every test expects: the time is fixed by options.
func (f *fixture) backupDir() string {
	return filepath.Join(f.folder, ".devzone.backup", "20990101-000000")
}

// read returns the content of folder/rel, failing the test when it cannot be read.
func (f *fixture) read(root, rel string) string {
	f.t.Helper()
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(data)
}

// version returns the version written in the manifest of the folder.
func (f *fixture) version() string {
	return manifest.FolderVersion(f.folder)
}
