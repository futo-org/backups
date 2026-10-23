# Columbo

Columbo investigates support tickets using account-scoped telemetry and read-only repository tools. Results go to the paired staff thread.

## Embedded repository

`mise columbo:build` and the container build generate a bare Git repository containing committed build HEAD, release tags, and their reachable history, then compile its files into the binary using `go:embed`. No ZIP, external repository volume, runtime Git executable, checkout, or shell is required. Git's native object encoding and packfiles remain intact so `go-git` can inspect exact versions and arbitrary embedded commit hashes.

The build excludes local Git configuration, credentials, hooks, remotes, working-tree changes, and unreachable objects. Source tools exclude secrets such as `.env` paths, dependencies, generated clients, fixtures, tests, binaries, symlinks, and oversized files. Excluded content is unavailable through the tools even if present in Git history.

The build refuses to publish a repository containing secret-bearing paths in any committed tree, including files deleted before HEAD. The path guard covers private environment files, private keys, credential files, and credential/secret directories; deliberate `.env.example`, `.env.sample`, `.env.template` files and Helm secret templates are allowed. It inspects paths, not secret values. Original Git objects and commit hashes are preserved; runtime source filters do not remove objects from the embedded history.

The tools list releases and files, read line ranges, perform bounded literal searches, compare a file between exact revisions, and read first-parent history. A read-only adapter bridges `embed.FS` into `go-git`; object hashes and decoded size limits are verified while loading an isolated in-memory repository. The in-memory store supports Git mutations internally without changing the embedded packfiles; LLM tools expose only read operations. Missing versions are reported as unavailable, with no substitution of HEAD. The release index shows at most 128 tags; full embedded commit hashes remain readable outside that index. Search results and file excerpts carry revision and line evidence.

Decoded Git objects are capped at 128 MiB, with a 4 MiB temporary decode cache. The image defaults to `GOMEMLIMIT=160MiB` to leave headroom within the chart’s 256 MiB container limit.

Direct `go build` uses the last generated repository, or reports source unavailable if none exists. To refresh it manually from the repository root:

```sh
cd packages/columbo
go run ./cmd/embed-repository -repo ../..
go build -o ../../dist/columbo .
```

## Initial ticket context

`COLUMBO_TICKET_QUIET_SECONDS` defaults to `60`; `0` disables the delay. Customer messages reset the timer while the initial investigation is pending. Waiting does not occupy an investigation worker. Once context fetching starts, new activity cannot cancel, restart, or schedule another automatic investigation. Staff requests run immediately and fetch the latest context.

Before triage, Columbo reads the latest 50 eligible ticket messages from the authenticated bot endpoint and checks the ticket identity and closed state. Unavailable context is retried three times, then reported to staff for a manual retry. Pending jobs and recently completed ticket IDs are bounded in-memory state; they do not survive a process restart.

Attachments are fetched only from canonical HTTPS Discord CDN attachment URLs, with every redirect checked. Limits are six files, 2 MiB per file, 6 MiB downloaded total, 32 KiB of text per file, 96 KiB of attachment text total, and three images. Text logs, JSON, and scripts are read as data. Supported image bytes are sent inline; a model without image support gets text with an explicit inspection limitation. Other binary formats, archives, unsafe URLs, and over-limit files produce omission notices. No files are extracted, executed, or passed to a shell.

## Built-artifact test

The opt-in test runs the actual container with a 256 MiB memory limit and local bot, telemetry, model, and HTTPS CDN fixtures. It checks the default minute of inactivity, a timer reset, a script attachment read without execution, exact Git versions, arbitrary commit reads, search, comparisons, history, and unavailable-version handling. It mounts only a public test CA; the repository comes from the binary.

```sh
docker build -f packages/columbo/Dockerfile -t columbo-support-context:e2e .
cd packages/columbo
COLUMBO_E2E_IMAGE=columbo-support-context:e2e go test -v ./e2e -run TestBuiltArtifact -count=1 -timeout=4m
```

`COLUMBO_E2E_BINARY` can select a native binary instead. `COLUMBO_E2E_QUIET_SECONDS` shortens the test delay for iteration; leave it unset to verify the production default.
