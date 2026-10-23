package source

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"testing"
	"testing/fstest"

	"github.com/go-git/go-billy/v5"
)

type disappearingDirectoryEntry struct{ err error }

func (e disappearingDirectoryEntry) Name() string               { return "maintenance.lock" }
func (e disappearingDirectoryEntry) IsDir() bool                { return false }
func (e disappearingDirectoryEntry) Type() fs.FileMode          { return 0 }
func (e disappearingDirectoryEntry) Info() (fs.FileInfo, error) { return nil, e.err }

type changingDirectoryFS struct {
	fs.FS
	entryError error
}

func (f changingDirectoryFS) ReadDir(name string) ([]fs.DirEntry, error) {
	entries, err := fs.ReadDir(f.FS, name)
	if err != nil {
		return nil, err
	}
	return append(entries, disappearingDirectoryEntry{err: f.entryError}), nil
}

func TestReadOnlyFilesystemHandlesEntriesRemovedDuringDirectoryEnumeration(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
	}{
		{"removed maintenance lock", fs.ErrNotExist},
		{"permission error", fs.ErrPermission},
	} {
		t.Run(test.name, func(t *testing.T) {
			filesystem := newReadOnlyFS(changingDirectoryFS{
				FS: fstest.MapFS{"objects/aa/1234": &fstest.MapFile{Data: []byte("object")}}, entryError: test.err,
			})

			entries, err := filesystem.ReadDir("objects")

			if errors.Is(test.err, fs.ErrNotExist) {
				if err != nil || len(entries) != 1 || entries[0].Name() != "aa" || !entries[0].IsDir() {
					t.Fatalf("vanished lock hid existing objects: %v %v", entries, err)
				}
			} else if !errors.Is(err, test.err) {
				t.Fatalf("directory error was ignored: %v", err)
			}
		})
	}
}

func TestReadOnlyFilesystemDeniesEveryMutation(t *testing.T) {
	filesystem := newReadOnlyFS(embeddedRepository)
	for _, test := range []struct {
		name      string
		operation func() error
	}{
		{"create", func() error { _, err := filesystem.Create("embedded/new.txt"); return err }},
		{"temporary file", func() error { _, err := filesystem.TempFile("embedded", "new"); return err }},
		{"rename", func() error { return filesystem.Rename("embedded/README.txt", "embedded/moved.txt") }},
		{"remove", func() error { return filesystem.Remove("embedded/README.txt") }},
		{"mkdir", func() error { return filesystem.MkdirAll("new/path", 0755) }},
		{"symlink", func() error { return filesystem.Symlink("/etc/passwd", "embedded/link") }},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.operation(); !errors.Is(err, fs.ErrPermission) {
				t.Fatalf("error=%v want permission denied", err)
			}
		})
	}
	for _, flags := range []int{os.O_WRONLY, os.O_RDWR, os.O_APPEND, os.O_CREATE, os.O_EXCL, os.O_TRUNC, os.O_SYNC, os.O_RDWR | os.O_CREATE | os.O_TRUNC} {
		if _, err := filesystem.OpenFile("embedded/README.txt", flags, 0600); !errors.Is(err, fs.ErrPermission) {
			t.Errorf("open flags=%d error=%v want permission denied", flags, err)
		}
	}
	if _, err := filesystem.Stat("embedded/README.txt"); err != nil {
		t.Fatalf("mutation attempts changed the original file: %v", err)
	}
	if _, err := filesystem.Stat("embedded/new.txt"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("mutation created a file: %v", err)
	}
	if filesystem.Capabilities() != billy.ReadCapability|billy.SeekCapability {
		t.Fatalf("unexpected capabilities: %d", filesystem.Capabilities())
	}
}

func TestReadOnlyFileSupportsReadSeekAndReaderAt(t *testing.T) {
	filesystem := newReadOnlyFS(embeddedRepository)
	expected, err := fs.ReadFile(embeddedRepository, "embedded/README.txt")
	if err != nil {
		t.Fatal(err)
	}
	file, err := filesystem.Open("/embedded/README.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := file.Close(); err != nil {
			t.Error(err)
		}
	}()
	if file.Name() != "/embedded/README.txt" {
		t.Fatalf("name=%s", file.Name())
	}
	info, err := filesystem.Stat("embedded/README.txt")
	if err != nil || info.Size() != int64(len(expected)) || info.IsDir() {
		t.Fatalf("stat=%v error=%v", info, err)
	}
	if offset, err := file.Seek(6, io.SeekStart); err != nil || offset != 6 {
		t.Fatalf("seek offset=%d error=%v", offset, err)
	}
	readAt := make([]byte, 5)
	if count, err := file.ReadAt(readAt, 0); err != nil || count != 5 || string(readAt) != string(expected[:5]) {
		t.Fatalf("readAt=%q count=%d error=%v", readAt, count, err)
	}
	read := make([]byte, 5)
	if count, err := file.Read(read); err != nil || count != 5 || string(read) != string(expected[6:11]) {
		t.Fatalf("read=%q count=%d error=%v", read, count, err)
	}
	if _, err := file.Seek(-4, io.SeekEnd); err != nil {
		t.Fatal(err)
	}
	remaining, err := io.ReadAll(file)
	if err != nil || string(remaining) != string(expected[len(expected)-4:]) {
		t.Fatalf("remaining=%q error=%v", remaining, err)
	}
	for _, test := range []struct {
		name      string
		operation func() error
	}{
		{"write", func() error {
			count, err := file.Write([]byte("overwrite"))
			if count != 0 {
				t.Errorf("write count=%d", count)
			}
			return err
		}},
		{"truncate", func() error { return file.Truncate(0) }},
		{"lock", file.Lock},
		{"unlock", file.Unlock},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.operation(); !errors.Is(err, fs.ErrPermission) {
				t.Fatalf("error=%v want permission denied", err)
			}
		})
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	actual, err := io.ReadAll(file)
	if err != nil || string(actual) != string(expected) {
		t.Fatalf("failed mutation changed data: %q error=%v", actual, err)
	}
}

func TestReadOnlyFilesystemRejectsTraversalAcrossEveryReadBoundary(t *testing.T) {
	filesystem := newReadOnlyFS(embeddedRepository)
	for _, name := range []string{"../README.txt", "embedded/../README.txt", "/../etc/passwd", "embedded/../../etc/passwd", "embedded\\..\\etc\\passwd", "embedded/README.txt\x00", "//etc/passwd"} {
		t.Run(name, func(t *testing.T) {
			for _, operation := range []struct {
				name string
				run  func() error
			}{
				{"open", func() error { _, err := filesystem.Open(name); return err }},
				{"open file", func() error { _, err := filesystem.OpenFile(name, os.O_RDONLY, 0); return err }},
				{"stat", func() error { _, err := filesystem.Stat(name); return err }},
				{"lstat", func() error { _, err := filesystem.Lstat(name); return err }},
				{"read dir", func() error { _, err := filesystem.ReadDir(name); return err }},
				{"chroot", func() error { _, err := filesystem.Chroot(name); return err }},
			} {
				t.Run(operation.name, func(t *testing.T) {
					if err := operation.run(); !errors.Is(err, fs.ErrInvalid) {
						t.Fatalf("path=%q error=%v want invalid path", name, err)
					}
				})
			}
		})
	}
	for _, name := range []string{"/etc/passwd", "/proc/self/environ"} {
		if _, err := filesystem.Open(name); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("host path=%q error=%v", name, err)
		}
	}
	if _, err := filesystem.Readlink("/etc/passwd"); !errors.Is(err, fs.ErrInvalid) {
		t.Fatalf("readlink error=%v", err)
	}
}

func TestReadOnlyFilesystemChrootKeepsAnEmbeddedNamespace(t *testing.T) {
	filesystem := newReadOnlyFS(embeddedRepository)
	if filesystem.Root() != "/" || filesystem.Join("embedded", "README.txt") != "embedded/README.txt" {
		t.Fatal("unexpected filesystem paths")
	}
	rooted, err := filesystem.Chroot("/embedded")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := rooted.ReadDir("/")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range entries {
		if entry.Name() == "README.txt" {
			found = true
		}
	}
	if !found {
		t.Fatalf("embedded README missing: %v", entries)
	}
	file, err := rooted.Open("/README.txt")
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(file)
	if closeErr := file.Close(); closeErr != nil {
		t.Error(closeErr)
	}
	if err != nil || len(data) == 0 {
		t.Fatalf("read=%q error=%v", data, err)
	}
	info, err := rooted.Lstat("README.txt")
	if err != nil || info.Name() != "README.txt" || info.Size() != int64(len(data)) {
		t.Fatalf("lstat=%v error=%v", info, err)
	}
	if _, err := rooted.Open("/embedded/README.txt"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("chroot escaped to original namespace: %v", err)
	}
	if _, err := rooted.Open("../embedded/README.txt"); !errors.Is(err, fs.ErrInvalid) {
		t.Fatalf("chroot accepted traversal: %v", err)
	}
	if _, err := rooted.Create("new.txt"); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("chroot allowed write: %v", err)
	}
}
