# syntax=docker/dockerfile:1.2

FROM golang:1.16-alpine
RUN apk add --no-cache gcc musl-dev
RUN wget -O- -nv https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s v1.27.0
WORKDIR /go/src/github.com/docker/buildx
RUN --mount=target=/go/src/github.com/docker/buildx --mount=target=/root/.cache,type=cache \
  golangci-lint run
