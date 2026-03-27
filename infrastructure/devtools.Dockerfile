FROM alpine:3.20

# Core utilities (python3 required by status.sh and other scripts for JSON parsing)
# util-linux provides GNU versions of flock, nsenter, unshare, etc. — replacing
# BusyBox stubs that lack flags like flock -w (timeout wait).
RUN apk add --no-cache bash curl ca-certificates tar gzip python3 util-linux

# Docker CLI (talks to host daemon via socket mount — no daemon installed here)
RUN apk add --no-cache docker-cli

# k3d
ARG K3D_VERSION=v5.7.4
RUN curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64" \
    -o /usr/local/bin/k3d && chmod +x /usr/local/bin/k3d

# kubectl
ARG KUBECTL_VERSION=v1.30.0
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# helm
ARG HELM_VERSION=v3.14.4
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm

WORKDIR /workspace
ENTRYPOINT []
CMD ["/bin/bash"]
