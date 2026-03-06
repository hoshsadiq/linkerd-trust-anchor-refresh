FROM alpine:3.21

ARG KUBECTL_VERSION=1.31.4

LABEL org.opencontainers.image.source="https://github.com/hoshsadiq/linkerd-trust-anchor-refresh"
LABEL org.opencontainers.image.description="Minimal runtime for linkerd-trust-anchor-refresh CronJob"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    curl \
    jq \
    openssl \
  && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/kubectl

COPY scripts/refresh-trust-anchor.sh /scripts/refresh-trust-anchor.sh
RUN chmod +x /scripts/refresh-trust-anchor.sh

RUN adduser -D -h /home/nonroot nonroot

USER nonroot
