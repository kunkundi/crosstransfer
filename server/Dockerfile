# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/ctserver ./cmd/ctserver
RUN mkdir -p /out/acme /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ctserver /ctserver
COPY --from=build --chown=65532:65532 /out/acme /var/lib/ctserver/acme
COPY --from=build --chown=65532:65532 /out/data /var/lib/ctserver/data
# Signaling (HTTP/WSS) and TURN (UDP) ports; the relay port range is host-networked.
EXPOSE 8080/tcp 3478/udp
USER nonroot:nonroot
ENTRYPOINT ["/ctserver"]
