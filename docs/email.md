# Email

Yucca sends transactional email through [Resend](https://resend.com/). The first (and so
far only) sender is the invite flow in yucca-admin-api; anything that later needs to email a user
builds on the same three pieces.

## Architecture

| Piece | Where | Role |
|---|---|---|
| `@common/emails` | `packages/emails` | Svelte email templates (better-svelte-email, Tailwind 4) styled after the web UI's `@immich/ui` theme, prebuilt to plain JS. Exposes `render*Email(props) → { subject, htmlBody, textBody }`. |
| `EmailRepository` | `@common/server/email` | Resend HTTP client over global `fetch` (`POST /emails`, `POST /emails/batch`, ≤100 per batch). Stamps `from` and, given a tag, a `category` tag. Resend accepts or rejects a batch as a whole, so one invalid address fails its whole batch. |
| Callers | e.g. `AllowlistService` | Render a template, hand the result to `EmailRepository`, record the outcome. |

Services wire `EmailRepository` into their `providers` array like any other repository; templates
are imported as functions. The renderer never runs in the request path of the web app — emails are
rendered inside the NestJS process from the prebuilt `@common/emails` dist.

**Degraded mode:** without `RESEND_API_KEY` the repository logs and skips every send.
Environments that don't care about email keep working; nothing crashes at boot.

## Invite flow

`POST /allowlist/invite` and `POST /allowlist/invite-batch` (yucca-admin-api, driven by yuctl)
email every affected entry whose `userAllowlist.inviteEmailSentAt` is still null, then stamp it on
success. Re-running an invite is therefore a safe retry that only reaches the not-yet-emailed
entries; a rejected address stays null and is retried next time. The email carries the invite code
and links to `${WEB_BASE_URL}/login/invite`.

## Configuration

| Env var | Meaning | Default |
|---|---|---|
| `RESEND_API_KEY` | Resend API key, `sending_access` for the from-address domain (secret) | unset → log-and-skip |
| `RESEND_API_URL` | Resend endpoint; dev points it at the mock | `https://api.resend.com` |
| `EMAIL_FROM_ADDRESS` | `From` header | `FUTO Backups <noreply@backups.futo.cloud>` |
| `WEB_BASE_URL` | Base for links in emails (yucca-admin-api) | `http://localhost:5173` |

The boundary rule from [feature-flags.md](feature-flags.md) applies: these are deployment config
(env/Secret/cluster-settings), not feature flags. In staging/prod the token rides in the
TF-provisioned `yucca-admin-api` Secret; the from-address and `WEB_BASE_URL` come from the base
HelmRelease + cluster-settings.

## Local dev

Nothing leaves the machine. The app speaks the real Resend wire protocol to an in-repo mock,
which delivers into a [Mailpit](https://mailpit.axllent.org/) inbox:

- **compose (`mise dev`)**: `mock-resend-provider` on `localhost:8093`, Mailpit UI on
  `http://localhost:8025`. The yucca-admin-api dev env defaults point at the mock.
- **k3d/Tilt**: `yucca-mock-resend` + `yucca-mailpit` (dev-only HelmReleases under
  `kubernetes/apps/dev/local`), same ports via the Tilt port-forwards.
- **e2e/tests**: assert through Mailpit's REST API (`GET /api/v1/messages`, search, message body);
  unit/integration tests mock or override `EmailRepository` instead.

To send *real* email from a dev machine, set `RESEND_API_URL` + `RESEND_API_KEY` in
`.env` (see `.env.example`).

## Adding a template

1. Add `packages/emails/src/emails/<name>.svelte` (compose with `src/lib/layout.svelte` and
   `@better-svelte-email/components`; Tailwind classes only — the renderer inlines them).
2. Export a typed `render<Name>Email()` from `packages/emails/src/index.ts`.
3. Preview while iterating: `pnpm --filter @common/emails preview`.
4. Call it from a service and pass the result to `EmailRepository.send`/`sendBatch` with a `tag`.

Email HTML is its own dialect: no CSS variables, no `oklch()`, table-friendly markup — which is
why `src/theme.ts` mirrors the `@immich/ui` palette as literal hex and templates never import web
components directly.
