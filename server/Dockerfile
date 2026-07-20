FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=development

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY cmd ./cmd
COPY internal ./internal
COPY web ./web

RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/clip-live-share-server ./cmd/clip-live-share-server

FROM alpine:3.20

ARG VERSION=development

RUN apk --no-cache add ca-certificates \
    && addgroup -S clip \
    && adduser -S -D -H -G clip clip

COPY --from=builder --chown=clip:clip /out/clip-live-share-server /usr/local/bin/clip-live-share-server

LABEL org.opencontainers.image.title="Clip Live Share Server" \
      org.opencontainers.image.description="Privacy-minimal signaling for Clip Live Share" \
      org.opencontainers.image.source="https://github.com/tomas-lejdung/Clip" \
      org.opencontainers.image.version=$VERSION

USER clip:clip
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1

ENTRYPOINT ["/usr/local/bin/clip-live-share-server"]
