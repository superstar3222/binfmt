# syntax=docker/dockerfile:1.3-labs

ARG GO_VERSION=1.17

ARG ALPINE_VERSION=3.14
ARG ALPINE_BASE=alpine:${ALPINE_VERSION}

ARG QEMU_VERSION=head
ARG QEMU_REPO=https://github.com/qemu/qemu

# xx is a helper for cross-compilation
FROM --platform=$BUILDPLATFORM tonistiigi/xx@sha256:56b19a5fb89b99195ec494d59ad34370d14540858c1f56c560ec1e7f2d1c177f AS xx

FROM --platform=$BUILDPLATFORM ${ALPINE_BASE} AS src
RUN apk add --no-cache git patch

WORKDIR /src
ARG QEMU_VERSION
ARG QEMU_REPO
RUN git clone $QEMU_REPO && cd qemu && git checkout $QEMU_VERSION
COPY patches patches
ARG QEMU_PATCHES=cpu-max
ARG QEMU_PATCHES_ALL=${QEMU_PATCHES},alpine-patches,zero-init-msghdr,sched
ARG QEMU_PRESERVE_ARGV0
RUN <<eof
  set -ex
  if [ "${QEMU_PATCHES_ALL#*alpine-patches}" != "${QEMU_PATCHES_ALL}" ]; then
    ver="$(cat qemu/VERSION)"
    for l in $(cat patches/aports.config); do
      if [ "$(printf "$ver\n$l" | sort -V | head -n 1)" != "$ver" ]; then
        commit=$(echo $l | cut -d, -f2)
        rmlist=$(echo $l | cut -d, -f3)
        break
      fi
    done
    mkdir -p aports && cd aports && git init
    git fetch --depth 1 https://github.com/alpinelinux/aports.git "$commit"
    git checkout FETCH_HEAD
    mkdir -p ../patches/alpine-patches
    for f in $(echo $rmlist | tr ";" "\n"); do
      rm community/qemu/*${f}*.patch || true
    done
    cp -a community/qemu/*.patch ../patches/alpine-patches/
    cd - && rm -rf aports
  fi
  if [ -n "${QEMU_PRESERVE_ARGV0}" ]; then
    QEMU_PATCHES_ALL="${QEMU_PATCHES_ALL},preserve-argv0"
  fi
  cd qemu
  for p in $(echo $QEMU_PATCHES_ALL | tr ',' '\n'); do
    for f in  ../patches/$p/*.patch; do echo "apply $f"; patch -p1 < $f; done
  done
  scripts/git-submodule.sh update ui/keycodemapdb tests/fp/berkeley-testfloat-3 tests/fp/berkeley-softfloat-3 dtc slirp
eof

FROM --platform=$BUILDPLATFORM ${ALPINE_BASE} AS base
RUN apk add --no-cache git clang lld python3 llvm make ninja pkgconfig glib-dev gcc musl-dev perl bash
COPY --from=xx / /
ENV PATH=/qemu/install-scripts:$PATH
WORKDIR /qemu

ARG TARGETPLATFORM
RUN xx-apk add --no-cache musl-dev gcc glib-dev glib-static linux-headers zlib-static
RUN set -e; \
  [ "$(xx-info arch)" = "ppc64le" ] && XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple; \
  [ "$(xx-info arch)" = "386" ] && XX_CC_PREFER_LINKER=ld xx-clang --setup-target-triple; \
  true

FROM base AS build
ARG TARGETPLATFORM
ARG QEMU_VERSION QEMU_TARGETS
ENV AR=llvm-ar STRIP=llvm-strip
RUN --mount=target=.,from=src,src=/src/qemu,rw --mount=target=./install-scripts,src=scripts \
  TARGETPLATFORM=${TARGETPLATFORM} configure_qemu.sh && \
  make -j "$(getconf _NPROCESSORS_ONLN)" && \
  make install && \
  cd /usr/bin && for f in $(ls qemu-*); do xx-verify --static $f; done

ARG BINARY_PREFIX
RUN cd /usr/bin; [ -z "$BINARY_PREFIX" ] || for f in $(ls qemu-*); do ln -s $f $BINARY_PREFIX$f; done

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS binfmt
COPY --from=xx / /
ENV CGO_ENABLED=0
ARG TARGETPLATFORM
ARG QEMU_VERSION
WORKDIR /src
RUN apk add --no-cache git
RUN --mount=target=. \
  TARGETPLATFORM=$TARGETPLATFORM xx-go build \
    -ldflags "-X main.revision=$(git rev-parse --short HEAD) -X main.qemuVersion=${QEMU_VERSION}" \
    -o /go/bin/binfmt ./cmd/binfmt && \
    xx-verify --static /go/bin/binfmt

FROM build AS build-archive
COPY --from=binfmt /go/bin/binfmt /usr/bin/binfmt
RUN cd /usr/bin && mkdir -p /archive && \
  tar czvfh "/archive/${BINARY_PREFIX}qemu_${QEMU_VERSION}_$(echo $TARGETPLATFORM | sed 's/\//-/g').tar.gz" ${BINARY_PREFIX}qemu* && \
  tar czvfh "/archive/binfmt_$(echo $TARGETPLATFORM | sed 's/\//-/g').tar.gz" binfmt

FROM scratch AS binaries
ARG BINARY_PREFIX
COPY --from=build usr/bin/${BINARY_PREFIX}qemu-* /

FROM scratch AS archive
COPY --from=build-archive /archive/* /

FROM --platform=$BUILDPLATFORM tonistiigi/bats-assert AS assert

FROM golang:${GO_VERSION}-alpine AS buildkit-test
RUN apk add --no-cache bash bats
WORKDIR /work
COPY --from=assert . .
COPY test .
COPY --from=binaries / /usr/bin
RUN ./run.sh

FROM scratch
COPY --from=binaries / /usr/bin/
COPY --from=binfmt /go/bin/binfmt /usr/bin/binfmt
ARG QEMU_PRESERVE_ARGV0
ENV QEMU_PRESERVE_ARGV0=${QEMU_PRESERVE_ARGV0}
ENTRYPOINT [ "/usr/bin/binfmt" ]
VOLUME /tmp
