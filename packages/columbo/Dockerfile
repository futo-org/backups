ARG ALPINE_VERSION=3.23
# Pinned alpine runtime base. NOTE: this digest is alpine:3.23's, so it must NOT
# be appended to the golang base tag (which reuses ${ALPINE_VERSION}).
ARG ALPINE_IMAGE=alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

FROM golang:1.27.3-alpine${ALPINE_VERSION} AS builder
WORKDIR /app
RUN apk add --no-cache git

COPY packages/columbo/go.mod packages/columbo/go.sum ./
RUN go mod download

COPY packages/columbo/ ./
COPY .git /repository/.git
RUN go run ./cmd/embed-repository -repo /repository -output internal/source/embedded
RUN CGO_ENABLED=0 go build -o /columbo .

FROM ${ALPINE_IMAGE}

RUN apk add --no-cache dumb-init \
    && addgroup -g 1000 columbo && adduser -u 1000 -G columbo -s /bin/sh -D columbo

USER columbo

COPY --from=builder /columbo /usr/local/bin/columbo

ENV COLUMBO_PORT=3060
ENV GOMEMLIMIT=160MiB
EXPOSE 3060
CMD ["dumb-init", "columbo"]
