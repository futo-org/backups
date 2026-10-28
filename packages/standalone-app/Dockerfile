ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
ARG NODE_IMAGE=node:26.12.1-alpine3.23@sha256:b1f4228f07d424dbf2f50e605b4981816e240e640a49f27ec85fab72f00c14b1
ARG RESTIC_IMAGE=ghcr.io/futo-org/restic:sha-a24cc22@sha256:7b5cdba9cc8690ecc528e239e6f8b2cfb9ef3644895cafd0e0fa9003bcded1f6
ARG GOLANG_IMAGE=golang:1.27.3-alpine3.23@sha256:895e5feab11a4b3774d24ee3c9579028456b82ad37f42a9eb6f82adaf776a201

FROM ${ALPINE_IMAGE} AS manifests
WORKDIR /src
COPY . ./
RUN find . -type d -name node_modules -prune -exec rm -rf {} + && \
    find . -type f \
    ! -name 'package.json' \
    ! -name 'pnpm-lock.yaml' \
    ! -name 'pnpm-workspace.yaml' \
    ! -name '.npmrc' \
    -delete && \
    find . -type d -empty -delete

FROM ${RESTIC_IMAGE} AS restic

FROM ${GOLANG_IMAGE} AS proxy
WORKDIR /src
COPY packages/restic-proxy/go.mod packages/restic-proxy/go.sum ./
RUN go mod download
COPY packages/restic-proxy/ ./
RUN CGO_ENABLED=0 go build -o /restic-proxy .

FROM ${NODE_IMAGE} AS builder
WORKDIR /build-stage
ENV PNPM_HOME=/pnpm-store
RUN apk add --no-cache bash python3 build-base && \
    npm install --global pnpm@10.28.1 && \
    pnpm config set store-dir "$PNPM_HOME"

COPY --from=manifests /src ./
RUN --mount=type=cache,id=pnpm-standalone,target=/pnpm-store \
    pnpm install --frozen-lockfile

COPY . ./
RUN --mount=type=cache,id=pnpm-standalone,target=/pnpm-store \
    pnpm --filter @futo-org/backups-api-client build && \
    pnpm --filter @futo-org/backups-orchestrator-api build && \
    pnpm --filter @futo-org/backups-orchestrator-ui build && \
    NODE_ENV=production pnpm --filter @futo-org/backups-standalone build && \
    pnpm --filter @futo-org/backups-standalone deploy /deploy --prod --legacy

FROM ${ALPINE_IMAGE}

WORKDIR /app

RUN apk add --no-cache libstdc++ libatomic dumb-init su-exec \
    && addgroup -g 1000 node && adduser -u 1000 -G node -s /bin/sh -D node

COPY --from=builder /usr/local/bin/node /usr/local/bin/
COPY --from=restic /usr/bin/restic /usr/local/bin/
COPY --from=proxy /restic-proxy /usr/local/bin/
COPY --from=builder /deploy ./
COPY --chmod=0755 packages/standalone-app/docker-entrypoint.sh /usr/local/bin/

# orchestration-api silently falls back to direct restic when restic-proxy is
# not an executable on PATH. An invalid LOG_LEVEL exits 3 before binding, so
# this proves the binary runs on this platform without starting the proxy.
RUN LOG_LEVEL=invalid restic-proxy; [ $? -eq 3 ]

RUN mkdir -p /data /cache && chown node:node /data /cache /app
VOLUME /data
VOLUME /cache

ENV NODE_ENV="production"
ENV YUCCA_STATE_PATH="/data"
ENV YUCCA_CACHE_PATH="/cache"
ENV YUCCA_UI_PATH="/app/build"
ENV HOST="0.0.0.0"
ENV PORT=22676
EXPOSE 22676

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD wget -q --spider "http://127.0.0.1:${PORT}/" || exit 1

ENTRYPOINT ["dumb-init", "--", "docker-entrypoint.sh"]
CMD ["node", "dist/main.js"]
