package source

import (
	"embed"
	"errors"
	"io/fs"
)

//go:embed all:embedded
var embeddedRepository embed.FS

func Embedded() (*Repository, error) {
	files, err := fs.Sub(embeddedRepository, "embedded")
	if err != nil {
		return nil, err
	}
	if _, err := fs.Stat(files, "HEAD"); errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	return Open(files)
}
