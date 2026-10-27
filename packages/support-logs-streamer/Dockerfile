# support-logs-streamer Docker image

ARG ALPINE_VERSION=3.23
# Pinned alpine runtime base. NOTE: this digest is alpine:3.23's, so it must NOT
# be appended to the golang base tags (which reuse ${ALPINE_VERSION}).
ARG ALPINE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

FROM golang:1.27.3-alpine${ALPINE_VERSION} AS dev
WORKDIR /src
# air is pinned: @latest broke michael's build when v1.67.2 started requiring a
# newer Go than this base image ships (bump air and the golang tag together).
RUN go install github.com/air-verse/air@v1.67.1
COPY packages/support-logs-streamer/go.mod packages/support-logs-streamer/go.sum ./
RUN go mod download
COPY packages/support-logs-streamer/ ./
EXPOSE 3040
CMD ["air", "-c", ".air.toml"]

FROM golang:1.27.3-alpine${ALPINE_VERSION} AS builder
WORKDIR /app

COPY packages/support-logs-streamer/go.mod packages/support-logs-streamer/go.sum ./
RUN go mod download

COPY packages/support-logs-streamer/ ./
RUN CGO_ENABLED=0 go build -o /support-logs-streamer .

FROM ${ALPINE_IMAGE}

RUN apk add --no-cache dumb-init \
    && addgroup -g 1000 support-logs-streamer && adduser -u 1000 -G support-logs-streamer -s /bin/sh -D support-logs-streamer

USER support-logs-streamer

COPY --from=builder /support-logs-streamer /usr/local/bin/support-logs-streamer

ENV SUPPORT_LOGS_PORT=3040
EXPOSE 3040
CMD ["dumb-init", "support-logs-streamer"]
