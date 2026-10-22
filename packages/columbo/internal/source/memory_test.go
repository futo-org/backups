package source

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/cache"
	"github.com/go-git/go-git/v5/storage/filesystem"
	"github.com/go-git/go-git/v5/storage/memory"
)

func gitFilesDigest(t *testing.T, files fs.FS) [sha256.Size]byte {
	t.Helper()
	hash := sha256.New()
	if err := fs.WalkDir(files, ".", func(name string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		data, err := fs.ReadFile(files, name)
		if err != nil {
			return err
		}
		_, _ = hash.Write([]byte(name + "\x00"))
		_, _ = hash.Write(data)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return [sha256.Size]byte(hash.Sum(nil))
}

func TestMemoryRepositoryCopiesGitStateAndKeepsMutationsOffTheBase(t *testing.T) {
	_, _, directory := sourceFixture(t)
	head := fixtureGit(t, directory, "rev-parse", "HEAD")
	fixtureGit(t, directory, "config", "user.name", "Embedded fixture")
	if err := os.WriteFile(filepath.Join(directory, ".git", "shallow"), []byte(head+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	files := os.DirFS(filepath.Join(directory, ".git"))
	before := gitFilesDigest(t, files)
	base := filesystem.NewStorage(newReadOnlyFS(files), cache.NewObjectLRUDefault())

	snapshot, err := memoryRepository(base)
	if err != nil {
		t.Fatal(err)
	}
	repository, err := git.Open(snapshot, nil)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := repository.Head()
	if err != nil || resolved.Hash().String() != head {
		t.Fatalf("HEAD was not preserved: %v %v", resolved, err)
	}
	ref, err := snapshot.Reference(plumbing.NewTagReferenceName("v1.0.0"))
	if err != nil || ref.Hash().IsZero() {
		t.Fatalf("release ref was not preserved: %v %v", ref, err)
	}
	config, err := snapshot.Config()
	if err != nil || config.User.Name != "Embedded fixture" {
		t.Fatalf("Git config was not preserved: %+v %v", config, err)
	}
	shallow, err := snapshot.Shallow()
	if err != nil || len(shallow) != 1 || shallow[0].String() != head {
		t.Fatalf("shallow history was not preserved: %v %v", shallow, err)
	}
	commit, err := repository.CommitObject(resolved.Hash())
	if err != nil {
		t.Fatal(err)
	}
	file, err := commit.File("src/client.go")
	if err != nil {
		t.Fatal(err)
	}
	contents, err := file.Contents()
	if err != nil || !strings.Contains(contents, "return true") {
		t.Fatalf("object contents were not preserved: %q %v", contents, err)
	}
	for hash, object := range snapshot.Objects {
		if _, ok := object.(*plumbing.MemoryObject); !ok {
			t.Fatalf("object %s still depends on filesystem-backed storage: %T", hash, object)
		}
	}
	object := snapshot.NewEncodedObject()
	object.SetType(plumbing.BlobObject)
	writer, err := object.Writer()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(writer, "memory-only object"); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	hash, err := snapshot.SetEncodedObject(object)
	if err != nil {
		t.Fatal(err)
	}
	if err := snapshot.SetReference(plumbing.NewHashReference("refs/heads/memory-only", hash)); err != nil {
		t.Fatal(err)
	}
	if _, err := snapshot.EncodedObject(plumbing.BlobObject, hash); err != nil {
		t.Fatalf("in-memory object mutation failed: %v", err)
	}
	if err := base.HasEncodedObject(hash); !errors.Is(err, plumbing.ErrObjectNotFound) {
		t.Fatalf("in-memory object reached base: %v", err)
	}
	if _, err := base.Reference("refs/heads/memory-only"); !errors.Is(err, plumbing.ErrReferenceNotFound) {
		t.Fatalf("in-memory ref reached base: %v", err)
	}
	config.User.Name = "Memory mutation"
	if err := snapshot.SetConfig(config); err != nil {
		t.Fatal(err)
	}
	if err := snapshot.SetShallow(nil); err != nil {
		t.Fatal(err)
	}
	if got := gitFilesDigest(t, files); got != before {
		t.Fatal("in-memory mutations changed embedded base files")
	}
}

type declaredGitObject struct {
	plumbing.MemoryObject
	size        int64
	hash        plumbing.Hash
	data        []byte
	readerCalls int
}

func (o *declaredGitObject) Size() int64               { return o.size }
func (o *declaredGitObject) Hash() plumbing.Hash       { return o.hash }
func (o *declaredGitObject) Type() plumbing.ObjectType { return plumbing.BlobObject }
func (o *declaredGitObject) Reader() (io.ReadCloser, error) {
	o.readerCalls++
	return io.NopCloser(bytes.NewReader(o.data)), nil
}

func TestMemoryRepositoryRejectsOversizedObjectsBeforeReading(t *testing.T) {
	for _, size := range []int64{-1, maxDecodedRepositoryBytes + 1} {
		object := &declaredGitObject{size: size, data: []byte("data"), hash: plumbing.ComputeHash(plumbing.BlobObject, []byte("data"))}
		base := memory.NewStorage()
		if _, err := base.SetEncodedObject(object); err != nil {
			t.Fatal(err)
		}

		_, err := memoryRepository(base)

		if err == nil || !strings.Contains(err.Error(), "memory limits") || object.readerCalls != 0 {
			t.Fatalf("invalid object size=%d reader calls=%d error=%v", size, object.readerCalls, err)
		}
	}
}

func TestMemoryRepositoryRejectsObjectSizeAndHashCorruption(t *testing.T) {
	for _, test := range []struct {
		name string
		size int64
		hash plumbing.Hash
	}{
		{"underreported size", 3, plumbing.ComputeHash(plumbing.BlobObject, []byte("data"))},
		{"overreported size", 5, plumbing.ComputeHash(plumbing.BlobObject, []byte("data"))},
		{"incorrect hash", 4, plumbing.ComputeHash(plumbing.BlobObject, []byte("other"))},
	} {
		t.Run(test.name, func(t *testing.T) {
			object := &declaredGitObject{size: test.size, data: []byte("data"), hash: test.hash}
			base := memory.NewStorage()
			if _, err := base.SetEncodedObject(object); err != nil {
				t.Fatal(err)
			}

			_, err := memoryRepository(base)

			if err == nil || !strings.Contains(err.Error(), "integrity mismatch") || object.readerCalls != 1 {
				t.Fatalf("corrupt Git object accepted: calls=%d error=%v", object.readerCalls, err)
			}
		})
	}
}

func TestMemoryRepositoryCopiesLargeDeltaPackedObjectsWithoutChangingTheirBytes(t *testing.T) {
	directory := t.TempDir()
	fixtureGit(t, directory, "init", "-b", "main")
	contents := make(map[plumbing.Hash]string)
	baseData := make([]byte, MaxFileBytes+(256<<10))
	for offset := 0; offset < len(baseData); offset += sha256.Size {
		hash := sha256.Sum256([]byte(fmt.Sprintf("block-%d", offset)))
		copy(baseData[offset:], hash[:])
	}
	targetData := bytes.Join([][]byte{baseData[400000:420000], baseData[:20000], baseData[700000:720000], baseData[100000:600000]}, nil)
	for _, text := range []string{string(targetData), string(baseData)} {
		writeFiles(t, directory, map[string]string{"src/large.log.txt": text})
		fixtureGit(t, directory, "commit", "-m", "fixture large source")
		hash := plumbing.NewHash(fixtureGit(t, directory, "rev-parse", "HEAD:src/large.log.txt"))
		contents[hash] = text
	}
	fixtureGit(t, directory, "repack", "-a", "-d", "-f", "--window=50", "--depth=50")
	indexes, err := filepath.Glob(filepath.Join(directory, ".git", "objects", "pack", "*.idx"))
	if err != nil || len(indexes) != 1 {
		t.Fatalf("packed fixture unavailable: %v %v", indexes, err)
	}
	deltas := 0
	for _, line := range strings.Split(fixtureGit(t, directory, "verify-pack", "-v", indexes[0]), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 7 && len(contents[plumbing.NewHash(fields[0])]) > MaxFileBytes {
			deltas++
		}
	}
	if deltas == 0 {
		t.Fatal("fixture has no large delta-packed objects")
	}

	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	for hash, expected := range contents {
		blob, err := repository.git.BlobObject(hash)
		if err != nil {
			t.Fatal(err)
		}
		reader, err := blob.Reader()
		if err != nil {
			t.Fatal(err)
		}
		actual, readErr := io.ReadAll(reader)
		closeErr := reader.Close()
		if readErr != nil || closeErr != nil || string(actual) != expected {
			t.Fatalf("large delta object %s changed: bytes=%d expected=%d readError=%v closeError=%v", hash, len(actual), len(expected), readErr, closeErr)
		}
	}
}
