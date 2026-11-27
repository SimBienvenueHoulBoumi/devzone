package update

import (
	"io"
	"io/fs"
	"os"
)

// copyEntry copies src into dst for the backup, as cp -P -p did: a symbolic link
// is recreated as a link, a file is copied with its permissions. Why: a backup of
// a link must not hold a copy of its target, which may be outside the devzone and
// is not the user's file to save.
func copyEntry(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		target, err := os.Readlink(src)
		if err != nil {
			return err
		}
		return os.Symlink(target, dst)
	}
	return copyFile(src, dst, info.Mode().Perm())
}

// copyFile copies the content of src to dst, created or truncated, then sets its
// permission bits to mode. Why: the mode is set after the write because an
// existing destination keeps its old mode otherwise, and the package's executable
// scripts must stay executable.
func copyFile(src, dst string, mode fs.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
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
	return os.Chmod(dst, mode)
}

// isRegular reports whether path is a regular file, following links as the shell
// test -f does.
func isRegular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
