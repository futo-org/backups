# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## ⚠️ CRITICAL — LIFE OR DEATH: zero code comments

**This is the most important rule in this file. Violating it is treated as a failed task.**
Never write a comment that narrates, restates, or explains what the code already says — no
"fetch the user", no "call the service", no explaining your change to the reviewer. Make the
code self-explanatory instead: better names, smaller functions.

```ts
// BAD — restates the code. Never do this:
// fetch the user's repositories
const repos = await this.repositoryService.list(userId);

// GOOD — no comment; the code already says it:
const repos = await this.repositoryService.list(userId);
```

The only permitted comment captures something the code *cannot* express — a why, a constraint,
a gotcha a reader would otherwise miss. These are rare. When in doubt, do not comment.
**Before finishing any edit, re-read your diff and delete every comment that fails this bar.**

Charts, the Flux dev tree and workflows follow the same bar, but there a comment recording why a
value deviates from its default, or what breaks when it changes, is usually the only place that
knowledge can live.

## What this is

FUTO Backups is a multi-tenant **backup service**: OIDC-authenticated users get S3-backed
[restic](https://restic.net/) repositories. This repository holds the application
(`packages/`), its Helm charts (`charts/`) and the local development stack (`compose.yml`,
`Tiltfile`, `kubernetes/apps/dev/local`). The production infrastructure lives in a separate,
private repository; nothing here may depend on it.

## Tooling

- Everything runs through **[mise](https://mise.jdx.dev/)** tasks (`.mise/tasks/` scripts +
  `.mise/config.toml` aggregates). mise pins every binary (node, pnpm, go, kubectl, helm, tilt…)
  — do not assume a tool is on PATH outside of mise.
- **pnpm workspaces** with a **catalog** (`pnpm-workspace.yaml`): add/bump shared deps in the
  catalog, referenced as `"catalog:"` in each `package.json` — not in individual packages.
- Optional dev secrets go in a gitignored root `.env` (copy `.env.example`); values may be
  literals or 1Password `op://` refs.

## Common commands

```bash
mise dev                  # compose-based dev: deps, docker infra (postgres/minio/mock-oidc/victoria-*), all *:dev
mise //packages/<pkg>:dev # one service, e.g. mise //packages/web:dev; Go services stay mise michael:dev
mise //packages/docs:dev  # docs site (packages/docs) on :36034

mise check                # lint + format check + svelte-check + unit tests (= the `checks` CI job)
mise fix                  # autofix lint/format + lingui extract
mise build                # build all packages
mise k8s:validate         # helm template + kubeconform + flux-local of the charts and dev tree

mise test                 # all unit tests (jest per NestJS pkg, vitest for web)
mise test:integration     # integration tests (--jobs 1; needs infra up)
mise test:integration:k3d # CI split: the database-backed suites; :s3 = the Ceph-backed ones
mise test:e2e             # e2e (needs the stack running); mise test:e2e:web = Playwright
mise //packages/<pkg>:test # one package; args after -- go to jest: mise //packages/yucca-api:test -- -t "name"

mise //packages/yucca-api:migrations <args>   # DB migrations (@immich/sql-tools; yucca-api owns the schema)
```

### k3d + Tilt (deployment-shaped dev)

`mise k3d:up` → `mise tilt:up` (build images, render charts from `kubernetes/apps/dev/local`,
port-forward, live_update); `tilt:down` / `k3d:down` to tear down. See the extensively commented
`Tiltfile`.

CI deploys resource subsets rather than the whole stack (`mise tilt:ci` still does everything):
`tilt:ci-infra` (integration — postgres, mock-oidc, victoria; **no Ceph**), then for e2e
`tilt:ci-ceph` (Rook only; builds no images, so it converges while the workspace installs)
followed by `tilt:ci-e2e` (the apps the e2e suites touch).

Ports: `5173` web · `3020` yucca-api · `3030` yucca-admin-api · `3010` michael ·
`8092` mock-oidc · `8025` mailpit · `8093` mock-resend · `9000` ceph rgw · `8428` victoria-metrics · `9428` victoria-logs.

## Application architecture

Backend services are **NestJS 11 + TypeScript**: controllers → services → repositories,
Zod-validated `env.ts`, JWT auth guards via `@AuthRoute()`, OTel from `@common/server`
(imported at bootstrap; pino logs, OTLP to victoria-*).

| Service | Lang | Role |
|---|---|---|
| `yucca-api` | NestJS | User-facing API. Owns auth (OIDC code + device flow, ES256 JWTs), repositories, **DB schema + migrations**. |
| `yucca-admin-api` | NestJS | Admin API (user/session/repository management). Same DB + JWT validation. |
| `michael` | Go | **Production** restic REST backend — S3 proxy with JWT verification, WORM enforcement, backend pooling. |
| `columbo` | Go | Ticket investigation agent: LLM loop (OpenRouter) over per-user-scoped o11y queries, answers only into staff threads. |
| `yucca-metrics-worker` | NestJS | 5-min cron: RadosGW usage → meter tables → per-connection rollup (`connectionMetrics`, billing floor), OTel gauges. |
| `futo-backups-bot` | NestJS | Discord support/invite bot. |
| `standalone-app` | Node | Single-container orchestrator (`ghcr.io/futo-org/backups/standalone`). |
| `restic-proxy` | Go | Local restic → FUTO Backups proxy (`ghcr.io/futo-org/backups/restic-proxy`). |
| `mock-oidc-provider` | Node | Dev/test OIDC IdP (code + device flow). |
| `mock-resend-provider` | Node | Dev/test Resend API mock; delivers into the Mailpit inbox. |
| `common` (`@common/server`) | TS lib | OTel init, pino repository, **feature-flag registry + connection-type registry**, Resend `EmailRepository` (`@common/server/email`). |
| `emails` (`@common/emails`) | Svelte lib | Transactional email templates (better-svelte-email, web theme), prebuilt to JS for the NestJS apps. See `docs/email.md`. |

**Frontend** (`packages/web`): SvelteKit 5 + Tailwind 4, `@immich/ui`, lingui i18n
(catalogue owned by orchestration-ui, one `.po` per language shared with the SDK: `mise //packages/yucca-sdk/orchestration-ui:lingui:*`;
compiled locales are generated, not edited), generated API client.
**Docs** (`packages/docs`, https://docs.futo.cloud): the **end-user** documentation site (beta setup
guides for Immich and the standalone container). SvelteKit + `adapter-static`; every page is a
`src/routes/<section>/<slug>/+page.md` compiled by `@immich/svelte-markdown-preprocess` (front matter
`title`/`description`/`order`; sections in `src/lib/index.ts`). Deployed to Cloudflare Pages by
`.github/workflows/docs.yml`; every same-repo PR gets a preview. Internal/developer docs stay
in `docs/` and the per-directory READMEs — do not move them onto the site.
**`packages/yucca-sdk/`** (orchestration-api + orchestration-ui) is separately versioned and
added explicitly in `pnpm-workspace.yaml`.

**API client generation**: yucca-api DTOs → `mise //packages/yucca-api:sync-openapi` →
`mise //packages/yucca-api-client:build` (oazapfts) → `packages/yucca-api-client/src/fetch-client.ts`.
Generated — regenerate on contract changes, never hand-edit.

**Database**: PostgreSQL via **Kysely**. Schema in `packages/yucca-api/src/schema/`
(`tables/`, `migrations/`); yucca-api is the schema owner, other services read the same DB.

**Go services**: `michael`, `columbo` and `restic-proxy`, `internal/<pkg>`, aws-sdk-go-v2, zerolog.

### Connections, feature flags, token revocation

Full detail: `docs/connections.md`. The essentials:

- **Connections**: a user has N connection instances of type `immich`/`restic`; every repository
  has a NOT NULL `connectionId`. Device flow binds via `?connection_type=&connection_name=`;
  instance attribution is client-driven (`POST /connections/:id/adopt`), never guessed
  server-side. The `/connections` surface is open to every authenticated user.
- **Feature flags**: registry in code (`@common/server` `FeatureFlags`) + strict-boolean per-user
  overrides; resolution `override ?? registry default`. Flags gate non-default connection *types*
  (`connection-restic`); admin-provisioned connections bypass. Boundary rule:
  env/deployment settings = deployment config (ops-owned); feature flags = per-user product gating
  (admin-owned, runtime).
- **Billing**: `ConnectionTypeInfos` declares metering tiers and `minObjectSizeBytes` floor;
  metrics-worker computes `billableBytes = max(size, objects * floor)` per connection.
- **Revocation** (revocable types only, default `restic`): postgres is truth; michael checks
  L1 per-process cache → valkey verdict cache (`yucca:michael:verdict:<jti>`) → yucca-api
  introspection (`GET /internal/restic-tokens/:jti`). Revoke flips the DB row + best-effort DELs
  the valkey key; introspection outage honors the grace window then **fails closed**. Long-lived
  tokens are revocable-only.

## Charts and releases

- `charts/apps/*` package the services; `charts/lib/yucca-common` is the shared library,
  `charts/dev/*` and `charts/platform/{rook-ceph-cluster,ceph-objectuser}` are dev-only.
  Service names are pinned via `fullnameOverride` and selector labels via `nameOverride`, so
  renaming a chart never changes in-cluster DNS or an (immutable) Deployment selector.
- Every merge to `main` publishes `ghcr.io/futo-org/backups/<image>:0.0.<run>` and the charts as
  `oci://ghcr.io/futo-org/backups/charts/<chart>:0.0.<run>` (`deploy.yml`). A release
  (release-please, tag `v<version>`) retags the images `v<version>` and publishes `<version>`
  charts (`release-images.yml`), pushing the `api` chart last: the infrastructure repo watches
  it and opens its own promotion PR. A chart's `appVersion` is the image tag it shipped with.
- Image names live in the `deploy.yml` build matrix (`package` → `image`); `build-check.yml` and
  `release-images.yml` read that matrix, so add new images there.

## Conventions

- **Conventional commits** enforced on PRs (`feat(scope):`, `fix(scope):`, `chore:`); scopes
  like `michael`, `yucca-api`, `web`, `charts`, `ci`. Releases via release-please; the monorepo
  is single-versioned.
- **PR descriptions and commit messages: one line at most.** Always. The diff carries the
  detail; neither the PR body nor the commit message restates it.
- ESLint is strict on promises (`no-floating-promises`, `no-misused-promises`, `require-await`,
  `await-thenable` are errors). Prettier: single quotes, trailing commas, width 120.
- Generated files are eslint-ignored: `**/fetch-client.ts`, `packages/yucca-sdk/orchestration-ui/src/lib/locales`, `dist`,
  `build`, `.svelte-kit`.
- **Match the package you are in.** Read the surrounding code first; write code that looks like
  what is already there, not your own conventions. (And remember the life-or-death rule at the
  top: zero comments.)
