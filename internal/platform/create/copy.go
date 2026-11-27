package create

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// copyPackage copies the package items and manage/scripts of pkg into target,
// recursively, as `cp -R` does; a missing source item is an error.
func copyPackage(pkg, target string) error {
	for _, base := range PackageItems {
		if err := copyTree(filepath.Join(pkg, base), filepath.Join(target, base)); err != nil {
			return err
		}
	}
	return copyTree(filepath.Join(pkg, "manage", "scripts"), filepath.Join(target, "manage", "scripts"))
}

// copyTree copies a file or a directory recursively, preserving permissions
// and symbolic links, as `cp -R` does.
func copyTree(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return fmt.Errorf("cannot copy %s: %w", src, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		link, err := os.Readlink(src)
		if err != nil {
			return err
		}
		return os.Symlink(link, dst)
	}
	if !info.IsDir() {
		return copyFile(src, dst, info.Mode())
	}
	if err := os.MkdirAll(dst, info.Mode().Perm()|0o700); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := copyTree(filepath.Join(src, entry.Name()), filepath.Join(dst, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

// copyFile copies one regular file, preserving its permission bits.
func copyFile(src, dst string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode.Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chmod(dst, mode.Perm())
}
