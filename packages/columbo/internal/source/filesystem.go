package source

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/go-git/go-billy/v5"
)

type readOnlyFS struct{ files fs.FS }

func newReadOnlyFS(files fs.FS) *readOnlyFS { return &readOnlyFS{files: files} }
func (r *readOnlyFS) Capabilities() billy.Capability {
	return billy.ReadCapability | billy.SeekCapability
}
func (r *readOnlyFS) Root() string                                { return "/" }
func (r *readOnlyFS) Join(parts ...string) string                 { return path.Join(parts...) }
func (r *readOnlyFS) Create(string) (billy.File, error)           { return nil, fs.ErrPermission }
func (r *readOnlyFS) TempFile(string, string) (billy.File, error) { return nil, fs.ErrPermission }
func (r *readOnlyFS) Rename(string, string) error                 { return fs.ErrPermission }
func (r *readOnlyFS) Remove(string) error                         { return fs.ErrPermission }
func (r *readOnlyFS) MkdirAll(string, os.FileMode) error          { return fs.ErrPermission }
func (r *readOnlyFS) Symlink(string, string) error                { return fs.ErrPermission }
func (r *readOnlyFS) Readlink(string) (string, error)             { return "", fs.ErrInvalid }
func (r *readOnlyFS) Lstat(name string) (os.FileInfo, error)      { return r.Stat(name) }
func (r *readOnlyFS) Stat(name string) (os.FileInfo, error) {
	name, err := embeddedPath(name)
	if err != nil {
		return nil, err
	}
	return fs.Stat(r.files, name)
}
func (r *readOnlyFS) ReadDir(name string) ([]os.FileInfo, error) {
	name, err := embeddedPath(name)
	if err != nil {
		return nil, err
	}
	entries, err := fs.ReadDir(r.files, name)
	if err != nil {
		return nil, err
	}
	infos := make([]os.FileInfo, 0, len(entries))
	for _, entry := range entries {
		info, err := entry.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		infos = append(infos, info)
	}
	return infos, nil
}
func (r *readOnlyFS) Chroot(name string) (billy.Filesystem, error) {
	name, err := embeddedPath(name)
	if err != nil {
		return nil, err
	}
	files, err := fs.Sub(r.files, name)
	if err != nil {
		return nil, err
	}
	return newReadOnlyFS(files), nil
}
func (r *readOnlyFS) Open(name string) (billy.File, error) { return r.OpenFile(name, os.O_RDONLY, 0) }
func (r *readOnlyFS) OpenFile(name string, flags int, _ os.FileMode) (billy.File, error) {
	if flags != os.O_RDONLY {
		return nil, fs.ErrPermission
	}
	clean, err := embeddedPath(name)
	if err != nil {
		return nil, err
	}
	file, err := r.files.Open(clean)
	if err != nil {
		return nil, err
	}
	reader, ok := file.(interface {
		io.ReaderAt
		io.Seeker
	})
	if !ok {
		_ = file.Close()
		return nil, fs.ErrInvalid
	}
	return &readOnlyFile{File: file, ReaderAt: reader, Seeker: reader, name: name}, nil
}
func embeddedPath(name string) (string, error) {
	for _, part := range strings.Split(name, "/") {
		if part == ".." {
			return "", fs.ErrInvalid
		}
	}
	name = strings.TrimPrefix(name, "/")
	if name == "" {
		name = "."
	}
	if !fs.ValidPath(name) || strings.ContainsAny(name, "\\\x00") {
		return "", fs.ErrInvalid
	}
	return name, nil
}

type readOnlyFile struct {
	fs.File
	io.ReaderAt
	io.Seeker
	name string
}

func (r *readOnlyFile) Name() string              { return r.name }
func (r *readOnlyFile) Write([]byte) (int, error) { return 0, fs.ErrPermission }
func (r *readOnlyFile) Truncate(int64) error      { return fs.ErrPermission }
func (r *readOnlyFile) Lock() error               { return fs.ErrPermission }
func (r *readOnlyFile) Unlock() error             { return fs.ErrPermission }
