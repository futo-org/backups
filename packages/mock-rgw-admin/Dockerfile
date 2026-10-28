ARG ALPINE_VERSION=3.23

FROM node:25-alpine${ALPINE_VERSION} AS builder
WORKDIR /build
RUN npm install -g pnpm@10.28.1

COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY packages/mock-rgw-admin/package.json ./packages/mock-rgw-admin/
RUN pnpm install --frozen-lockfile --filter mock-rgw-admin

COPY packages/mock-rgw-admin ./packages/mock-rgw-admin
RUN pnpm --filter mock-rgw-admin build
RUN pnpm --filter mock-rgw-admin deploy /deploy --prod --legacy

FROM node:25-alpine${ALPINE_VERSION}
WORKDIR /usr/src/app
COPY --from=builder /deploy ./
USER node
ENV NODE_ENV=production
EXPOSE 80
CMD ["node", "dist/index.js"]
