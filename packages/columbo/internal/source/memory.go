package source

import (
	"fmt"
	"io"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/storage"
	"github.com/go-git/go-git/v5/storage/memory"
)

func memoryRepository(base storage.Storer) (*memory.Storage, error) {
	snapshot := memory.NewStorage()
	objects, err := base.IterEncodedObjects(plumbing.AnyObject)
	if err != nil {
		return nil, err
	}
	total, count := int64(0), 0
	err = objects.ForEach(func(encoded plumbing.EncodedObject) error {
		count++
		if encoded.Size() < 0 || encoded.Size() > maxDecodedRepositoryBytes-total || count > MaxRepositoryObjects {
			return fmt.Errorf("embedded Git objects exceed memory limits")
		}
		object := snapshot.NewEncodedObject()
		object.SetType(encoded.Type())
		object.SetSize(encoded.Size())
		reader, err := encoded.Reader()
		if err != nil {
			return err
		}
		writer, err := object.Writer()
		if err != nil {
			_ = reader.Close()
			return err
		}
		copied, copyErr := io.Copy(writer, io.LimitReader(reader, maxDecodedRepositoryBytes-total+1))
		readCloseErr := reader.Close()
		writeCloseErr := writer.Close()
		if copyErr != nil {
			return copyErr
		}
		if readCloseErr != nil {
			return readCloseErr
		}
		if writeCloseErr != nil {
			return writeCloseErr
		}
		if copied != encoded.Size() || object.Hash() != encoded.Hash() {
			return fmt.Errorf("embedded Git object integrity mismatch: expected=%s actual=%s type=%s declaredBytes=%d copiedBytes=%d", encoded.Hash(), object.Hash(), encoded.Type(), encoded.Size(), copied)
		}
		total += copied
		_, err = snapshot.SetEncodedObject(object)
		return err
	})
	if err != nil {
		return nil, err
	}
	references, err := base.IterReferences()
	if err != nil {
		return nil, err
	}
	if err := references.ForEach(snapshot.SetReference); err != nil {
		return nil, err
	}
	config, err := base.Config()
	if err != nil {
		return nil, err
	}
	if err := snapshot.SetConfig(config); err != nil {
		return nil, err
	}
	shallow, err := base.Shallow()
	if err != nil {
		return nil, err
	}
	if err := snapshot.SetShallow(shallow); err != nil {
		return nil, err
	}
	return snapshot, nil
}
