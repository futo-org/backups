package main

import (
	"context"
	"fmt"
	"path"
	"strings"

	"columbo/internal/source"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

type inspectedTree struct {
	hash   plumbing.Hash
	prefix string
}

func rejectSecretPaths(ctx context.Context, directory string) error {
	repository, err := git.PlainOpen(directory)
	if err != nil {
		return err
	}
	commits, err := repository.CommitObjects()
	if err != nil {
		return err
	}
	defer commits.Close()
	seen := make(map[inspectedTree]bool)
	return commits.ForEach(func(commit *object.Commit) error {
		pending := []inspectedTree{{hash: commit.TreeHash}}
		for len(pending) > 0 {
			if err := ctx.Err(); err != nil {
				return err
			}
			item := pending[len(pending)-1]
			pending = pending[:len(pending)-1]
			if seen[item] {
				continue
			}
			if len(seen) >= source.MaxRepositoryObjects {
				return fmt.Errorf("embedded Git path inspection exceeds object limit")
			}
			tree, err := repository.TreeObject(item.hash)
			if err != nil {
				return fmt.Errorf("inspect Git tree %s: %w", item.hash, err)
			}
			for _, entry := range tree.Entries {
				name := entry.Name
				if item.prefix != "" {
					name = item.prefix + "/" + name
				}
				if secretPath(name, entry.Mode == filemode.Dir) {
					return fmt.Errorf("refusing to embed secret-bearing path %q at commit %s", name, commit.Hash)
				}
				if entry.Mode == filemode.Dir {
					pending = append(pending, inspectedTree{hash: entry.Hash, prefix: name})
				}
			}
			seen[item] = true
		}
		return nil
	})
}

func secretPath(filename string, directory bool) bool {
	filename = strings.ToLower(filename)
	parts := strings.Split(filename, "/")
	for i, segment := range parts {
		if segment == "credentials" || segment == "secrets" || segment == ".ssh" || segment == ".aws" {
			return true
		}
		if strings.HasPrefix(segment, ".env") {
			publicTemplate := segment == ".env.example" || segment == ".env.sample" || segment == ".env.template" || filename == ".envrc"
			if !publicTemplate || directory || i != len(parts)-1 {
				return true
			}
		}
	}
	base := path.Base(filename)
	switch base {
	case ".netrc", "_netrc", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json", "credentials.yaml", "credentials.yml":
		return true
	case "secret.yaml", "secret.yml", "secrets.yaml", "secrets.yml", "secrets.json":
		return !strings.HasPrefix(filename, "charts/") || !strings.Contains(filename, "/templates/")
	}
	switch path.Ext(base) {
	case ".pem", ".key", ".p12", ".pfx":
		return true
	}
	return false
}
