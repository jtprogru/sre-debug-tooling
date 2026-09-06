# syntax=docker/dockerfile:1.7

# The base is pinned by digest, not by tag: an image you debug production with
# must be byte-identical on every rebuild. The digest is written out in full on
# each FROM rather than hidden behind an ARG, because that is the form
# dependabot reads - and a digest nothing updates is a frozen CVE state.
# Both FROM lines below carry the same digest and are bumped together.

# ---------------------------------------------------------------------------
# fetch: pull the pinned release binaries. Runs on the build platform, never
# under emulation, because it only downloads and unpacks - it never executes
# what it fetched.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS fetch

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY hack/tools-lib.sh hack/tools.list hack/tools.sha256 hack/fetch-tools.sh /hack/
RUN /hack/fetch-tools.sh slim "${TARGETARCH}" /out/slim \
    && /hack/fetch-tools.sh full "${TARGETARCH}" /out/full

# ---------------------------------------------------------------------------
# slim: network, DNS, HTTP/gRPC, TLS and pod logs. Closes most incidents.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS slim

ENV DEBIAN_FRONTEND=noninteractive

# Distro versions are intentionally unpinned. The digest above pins the base
# layer; apt still resolves against the current Debian archive, so a rebuild
# picks up security updates. That is the trade we want here - the parts that
# must not drift silently are the release binaries, and those are pinned by
# sha256 in hack/tools.sha256.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bind9-dnsutils \
        bind9-host \
        bsdextrautils \
        ca-certificates \
        conntrack \
        coreutils \
        curl \
        ethtool \
        file \
        htop \
        iperf3 \
        iproute2 \
        iptables \
        iputils-ping \
        iputils-tracepath \
        jq \
        less \
        lsof \
        mtr-tiny \
        netcat-openbsd \
        nftables \
        nmap \
        openssl \
        procps \
        psmisc \
        socat \
        strace \
        tcpdump \
        tmux \
        traceroute \
        tzdata \
        util-linux \
        vim-tiny \
        wget \
        xxd \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/slim/ /usr/local/bin/
# Keep the manifest inside the image so anyone in the pod can check what is
# baked in and at which version.
COPY --from=fetch /hack/tools.list /usr/local/share/sre-debug-tooling/tools.list

# Non-root by default so the image is admissible in a PSA "restricted"
# namespace. USER is numeric on purpose: with runAsNonRoot the kubelet refuses
# to start a container whose image declares a username it cannot resolve.
# tcpdump, strace and friends still need an explicit securityContext -
# see docs/en/runbooks/.
RUN groupadd --gid 1000 debug \
    && useradd --create-home --uid 1000 --gid 1000 --shell /bin/bash debug
USER 1000:1000
WORKDIR /home/debug

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="sre-debug-tooling" \
      org.opencontainers.image.description="Kubernetes service troubleshooting image (slim)" \
      org.opencontainers.image.source="https://github.com/jtprogru/sre-debug-tooling" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.jtprogru.debug.variant="slim"

CMD ["/bin/bash"]

# ---------------------------------------------------------------------------
# full: adds kernel/disk tracing, load generation and datastore clients.
# ---------------------------------------------------------------------------
FROM slim AS full

USER 0:0
ENV DEBIAN_FRONTEND=noninteractive

# linux-perf is deliberately absent: Debian builds it against the distro
# kernel, it almost never matches the node kernel, and a perf that silently
# reports nothing is worse than no perf at all.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        atop \
        binutils \
        bpftrace \
        cifs-utils \
        default-mysql-client \
        fio \
        gdb \
        iftop \
        ioping \
        ipvsadm \
        kcat \
        ncdu \
        nfs-common \
        openssh-client \
        postgresql-client \
        python3-minimal \
        redis-tools \
        rsync \
        sysstat \
        tshark \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out/full/ /usr/local/bin/

USER 1000:1000
WORKDIR /home/debug

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="sre-debug-tooling" \
      org.opencontainers.image.description="Kubernetes service troubleshooting image (full)" \
      org.opencontainers.image.source="https://github.com/jtprogru/sre-debug-tooling" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.jtprogru.debug.variant="full"

CMD ["/bin/bash"]
