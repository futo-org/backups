package main

import "testing"

func TestSecretPathRejectsPrivateFilesAndAllowsPublicTemplates(t *testing.T) {
	for _, filename := range []string{
		".env", ".env.production", "nested/.ENV.local", "nested/.envrc", "keys/server.pem", "keys/server.key", "keys/identity.p12", "keys/identity.pfx",
		".netrc", "home/id_rsa", "home/id_ed25519", "account/credentials.json", "credentials/token.txt", "nested/secrets/values.yaml",
		"secret.yaml", "settings/secrets.json", "charts/apps/api/secret.yaml", "charts/apps/api/secrets/values.yaml",
	} {
		t.Run(filename, func(t *testing.T) {
			if !secretPath(filename, false) {
				t.Fatalf("private path accepted: %s", filename)
			}
		})
	}
	for _, filename := range []string{
		".env.example", "nested/.env.sample", "nested/.env.template", ".envrc", "README.md", "src/secret.service.ts", "charts/apps/api/values.yaml",
		"charts/apps/api/templates/secret.yaml", "charts/apps/api/templates/secrets.yaml", "charts/apps/api/templates/_helpers.tpl",
	} {
		t.Run(filename, func(t *testing.T) {
			if secretPath(filename, false) {
				t.Fatalf("public template or source path rejected: %s", filename)
			}
		})
	}
	if !secretPath(".env.example", true) || !secretPath(".env.example/token.txt", false) {
		t.Fatal("public environment template allowance escaped its file boundary")
	}
}
