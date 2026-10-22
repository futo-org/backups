# FUTO Backups

FUTO Backups is a multi-tenant backup service: users sign in with OIDC and get
S3-backed [restic](https://restic.net/) repositories, with first-class support
for backing up [Immich](https://immich.app).

End-user documentation is published at https://docs.futo.cloud from `packages/docs`.

This repository holds the application, its container images and Helm charts,
and the local development stack. The infrastructure FUTO runs it on is managed
separately.

## Development

Ensure you have prerequisites installed:

- [Docker](https://docs.docker.com/engine/install/)
- [mise](https://mise.jdx.dev/getting-started.html)

If necessary, copy `.env.example` to `.env` and customise.

Then use mise:

```bash
mise dev # install deps, prep environment, start servers (compose-based)

mise check # lint, format check, svelte check, unit tests

mise test # unit tests
mise test:integration # integration tests
mise test:e2e # e2e tests
mise test:e2e:web # e2e web tests
```

### Running on k3d + Tilt (Kubernetes)

An alternative dev flow runs the stack the way it is deployed: Helm charts,
CloudNativePG, Rook-Ceph object storage and in-cluster service discovery. All
required tools (k3d, kubectl, helm, tilt) are installed via mise.

```bash
mise k3d:up       # create local k3d cluster + registry
mise tilt:up      # start Tilt; builds images, renders charts, port-forwards
# edit code — live_update syncs into running pods

mise tilt:down    # stop Tilt
mise k3d:down     # delete cluster
```

Ports forwarded to localhost:

- `5173` web, `3020` yucca-api, `3030` yucca-admin-api, `3010` michael
- `8092` mock-oidc, `8025` mailpit, `9000` ceph rgw (S3)
- `8428` victoria-metrics, `9428` victoria-logs

Tilt reads the HelmReleases under [`kubernetes/apps/dev/local`](./kubernetes/apps/dev/local)
to discover what to deploy, then builds and live-updates the images. Charts live
in `charts/` (a `yucca-common` library plus per-service charts).

## Images and charts

Every merge to `main` publishes images and charts tagged `0.0.<build>`; every
release publishes `v<version>` images and `<version>` charts.

| Image                                     | Chart                                            | Package                        |
| ----------------------------------------- | ------------------------------------------------ | ------------------------------ |
| `ghcr.io/futo-org/backups/api`            | `oci://ghcr.io/futo-org/backups/charts/api`            | `packages/yucca-api`           |
| `ghcr.io/futo-org/backups/admin-api`      | `oci://ghcr.io/futo-org/backups/charts/admin-api`      | `packages/yucca-admin-api`     |
| `ghcr.io/futo-org/backups/metrics-worker` | `oci://ghcr.io/futo-org/backups/charts/metrics-worker` | `packages/yucca-metrics-worker` |
| `ghcr.io/futo-org/backups/web`            | `oci://ghcr.io/futo-org/backups/charts/web`            | `packages/web`                 |
| `ghcr.io/futo-org/backups/michael`        | `oci://ghcr.io/futo-org/backups/charts/michael`        | `packages/michael`             |
| `ghcr.io/futo-org/backups/bot`            | `oci://ghcr.io/futo-org/backups/charts/bot`            | `packages/futo-backups-bot`    |
| `ghcr.io/futo-org/backups/columbo`        | `oci://ghcr.io/futo-org/backups/charts/columbo`        | `packages/columbo`             |
| `ghcr.io/futo-org/backups/standalone`     |                                                  | `packages/standalone-app`      |
| `ghcr.io/futo-org/backups/restic-proxy`   |                                                  | `packages/restic-proxy`        |

The `meta` (`.well-known` discovery) and `cnpg-cluster` (CloudNativePG database)
charts are published alongside under the same prefix.

A chart's `appVersion` is the image tag it was published with, so a chart
version alone pins the images it deploys.

## Support bot

`packages/futo-backups-bot` handles Discord tickets and optional Freshdesk syncing.
Ticket setup grants Attach Files in the support channel without changing channel
visibility or posting permissions. If a member-specific deny remains, the ticket
shows a visible explanation. Image and log attachments retain filenames and
captions; failed downloads are retried. The attachment limits are 18 MiB per
Freshdesk conversation and 8 MiB per file sent to Discord, where oversized files
are linked instead.

## License

[Source First License 1.1](./LICENSE).
