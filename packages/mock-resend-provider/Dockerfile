ARG ALPINE_VERSION=3.23

FROM node:26.12.1-alpine${ALPINE_VERSION} AS builder
WORKDIR /build
RUN npm install -g pnpm@10.28.1

COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY packages/mock-resend-provider/package.json ./packages/mock-resend-provider/
RUN pnpm install --frozen-lockfile --filter mock-resend-provider

COPY packages/mock-resend-provider ./packages/mock-resend-provider
RUN pnpm --filter mock-resend-provider build
RUN pnpm --filter mock-resend-provider deploy /deploy --prod --legacy

FROM node:26.12.1-alpine${ALPINE_VERSION}
WORKDIR /usr/src/app
COPY --from=builder /deploy ./
USER node
ENV NODE_ENV=production
EXPOSE 80
CMD ["node", "dist/index.js"]
