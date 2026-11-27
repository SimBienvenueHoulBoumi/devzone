package update

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// plan is everything an update will do, worked out before the first change: the
// files to back up, the files to remove, the locally modified files to ask about,
// and the old layouts to prune. Why: the refusals and the questions all come
// before any write, so a refused update leaves the folder untouched.
type plan struct {
	toSave   []string // sorted: backed up before they are replaced or removed
	toRemove []string // files of the old package, removed (manifest order)
	modified []string // sorted: changed by the user, asked about before replacing
	oldTrees []string // old layouts ("core", "scripts") pruned when they are empty
}

// buildPlan compares the folder with the package and with its manifest. pkgFiles
// are the files the package delivers; oldFiles the paths the manifest lists, sorted.
// Refused paths are reported on the error stream and skipped, never acted on.
func buildPlan(o Options, pkgFiles, oldFiles []string) plan {
	var p plan
	inPkg := map[string]bool{}
	for _, rel := range pkgFiles {
		inPkg[rel] = true
	}
	for _, rel := range pkgFiles {
		if !isRegular(filepath.Join(o.Folder, filepath.FromSlash(rel))) {
			continue
		}
		p.toSave = append(p.toSave, rel)
		if differsFromPackage(o, rel) {
			p.modified = append(p.modified, rel)
		}
	}
	for _, rel := range oldFiles {
		if rel == "" {
			continue
		}
		if !manifest.PathAllowed(rel) {
			refuse(o, rel)
			continue
		}
		if inPkg[rel] || manifest.IsProtected(rel) {
			continue
		}
		if !manifest.InsideFolder(o.Folder, rel) {
			refuse(o, rel)
			continue
		}
		p.toRemove = append(p.toRemove, rel)
		if !isRegular(filepath.Join(o.Folder, filepath.FromSlash(rel))) {
			continue
		}
		p.toSave = append(p.toSave, rel)
		sum, err := manifest.Checksum(filepath.Join(o.Folder, filepath.FromSlash(rel)))
		if want, ok := manifest.ManifestChecksum(o.Folder, rel); !ok || err != nil || sum != want {
			p.modified = append(p.modified, rel)
		}
	}
	p.addOldTrees(o)
	p.toSave = uniqueSorted(p.toSave)
	p.modified = uniqueSorted(p.modified)
	return p
}

// addOldTrees adds the files of the old layouts (core/, scripts/) that the package
// once delivered. Every such file is asked about, even with a manifest: removing a
// file of the old package is a change. A file the package never delivered is the
// user's and is kept.
func (p *plan) addOldTrees(o Options) {
	for _, tree := range []string{"core", "scripts"} {
		if !isDir(filepath.Join(o.Folder, tree)) || !manifest.OldTree(o.Folder, tree) {
			continue
		}
		p.oldTrees = append(p.oldTrees, tree)
		for _, rel := range regularFilesUnder(o.Folder, tree) {
			if !manifest.PathAllowed(rel) {
				refuse(o, rel)
				continue
			}
			if manifest.IsProtected(rel) || !manifest.KnownOldFile(o.Package, rel) {
				continue
			}
			p.toRemove = append(p.toRemove, rel)
			p.toSave = append(p.toSave, rel)
			p.modified = append(p.modified, rel)
		}
	}
}

// differsFromPackage tells whether the file rel of the folder differs from what
// the update would install. The manifest checksum is the reference; a file the
// manifest does not list is compared with the package copy, since it is new to
// the folder.
func differsFromPackage(o Options, rel string) bool {
	current, err := manifest.Checksum(filepath.Join(o.Folder, filepath.FromSlash(rel)))
	if err != nil {
		return true
	}
	want, ok := manifest.ManifestChecksum(o.Folder, rel)
	if !ok {
		want, err = manifest.Checksum(filepath.Join(o.Package, filepath.FromSlash(rel)))
		if err != nil {
			return true
		}
	}
	return current != want
}

// refuse reports a manifest path that is not acted on. The message is the one the
// shell printed, so the output of an update does not change.
func refuse(o Options, rel string) {
	fmt.Fprintf(o.Err, "devzone: manifest: refused path: %s\n", rel)
}

// regularFilesUnder lists the regular files under folder/tree, as paths relative
// to folder with slashes, sorted. A symbolic link is not listed (find -type f does
// not list it either): it is never followed, so nothing outside the tree is named.
func regularFilesUnder(folder, tree string) []string {
	var out []string
	base := filepath.Join(folder, tree)
	_ = filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			rel, relErr := filepath.Rel(folder, path)
			if relErr == nil {
				out = append(out, filepath.ToSlash(rel))
			}
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// uniqueSorted returns the values of list once each, sorted bytewise (LC_ALL=C
// sort -u in the shell version).
func uniqueSorted(list []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, v := range list {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

// sortedCopy returns a sorted copy of list: the paths of the manifest are read in
// sorted order, as the shell's "sort" gave them.
func sortedCopy(list []string) []string {
	out := append([]string{}, list...)
	sort.Strings(out)
	return out
}

// isDir reports whether path is a directory, following links as the shell test -d.
func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
