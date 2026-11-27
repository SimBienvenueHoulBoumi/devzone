package update

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// backupFolderName is the name of a backup folder: the time it was made, as the
// shell's "date +%Y%m%d-%H%M%S" wrote it.
func backupFolderName(now func() string) string {
	if now != nil {
		return now()
	}
	return time.Now().Format("20060102-150405")
}

// backup copies every file the update replaces or removes into a new folder of
// .devzone.backup/. Why: a replaced or removed file can always be recovered. A
// file already backed up under the same time name gets a numbered folder, so an
// earlier backup is never overwritten.
func backup(o Options, p plan) error {
	if len(p.toSave) == 0 {
		return nil
	}
	base := filepath.Join(o.Folder, ".devzone.backup", backupFolderName(o.Now))
	dir := base
	for n := 2; exists(dir); n++ {
		dir = fmt.Sprintf("%s-%d", base, n)
	}
	for _, rel := range p.toSave {
		src := filepath.Join(o.Folder, filepath.FromSlash(rel))
		if !isRegular(src) {
			continue
		}
		if !manifestInside(o, rel) {
			refuse(o, rel)
			continue
		}
		dst := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := copyEntry(src, dst); err != nil {
			return err
		}
	}
	fmt.Fprintf(o.Out, "Sauvegarde : %s\n", dir)
	return nil
}

// apply writes the package into the folder, removes the old package and the old
// layouts, then writes the manifest of the new package. Why: the manifest is the
// last step, so a failure part way leaves the old manifest, and the next update
// finds the files still to do.
func apply(o Options, p plan, pkgFiles []string, pkgVersion string) error {
	if err := manifest.CompleteGitignore(o.Folder); err != nil {
		return err
	}
	for _, rel := range pkgFiles {
		if err := copyFromPackage(o, rel); err != nil {
			return err
		}
	}
	for _, rel := range p.toRemove {
		src := filepath.Join(o.Folder, filepath.FromSlash(rel))
		if !isRegular(src) {
			continue
		}
		if !manifestInside(o, rel) {
			refuse(o, rel)
			continue
		}
		// os.Remove deletes a link itself, never the file it points to
		if err := os.Remove(src); err != nil {
			return err
		}
	}
	for _, tree := range p.oldTrees {
		pruneEmptyDirs(filepath.Join(o.Folder, tree))
	}
	if err := manifest.Write(o.Folder, pkgVersion, pkgFiles); err != nil {
		return err
	}
	return nil
}

// copyFromPackage installs one package file into the folder. A symbolic link in the
// folder is replaced by a real file, and the link's target is never written
// through. Why: the link is what the update replaces; what it points to belongs to
// someone else.
func copyFromPackage(o Options, rel string) error {
	dst := filepath.Join(o.Folder, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if !manifestInside(o, rel) {
		refuse(o, rel)
		return nil
	}
	if info, err := os.Lstat(dst); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		if err := os.Remove(dst); err != nil {
			return err
		}
		fmt.Fprintf(o.Err, "devzone: manifest: link replaced: %s\n", rel)
	}
	src := filepath.Join(o.Package, filepath.FromSlash(rel))
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	return copyFile(src, dst, info.Mode().Perm())
}

// pruneEmptyDirs removes the folders under dir that are empty, deepest first, and
// dir itself when it ends up empty. Why: only what became empty goes; a folder
// that still holds a user's file is kept whole.
func pruneEmptyDirs(dir string) {
	if !isDir(dir) {
		return
	}
	var dirs []string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			dirs = append(dirs, path)
		}
		return nil
	})
	sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
	for _, d := range dirs {
		_ = os.Remove(d) // fails, harmlessly, while the folder is not empty
	}
}

// manifestInside reports whether rel's parent folder stays under the devzone
// folder. The checks run again at each write, not only when the plan was made.
func manifestInside(o Options, rel string) bool {
	return manifest.InsideFolder(o.Folder, rel)
}

// exists reports whether path is there, whatever it is (a link counts).
func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}
