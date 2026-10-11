#!/usr/bin/env bash
# Build the ProxySQL operator image from its release tag and push it to the
# in-cluster Zot registry (apps/zot/), because upstream's own image
# (ghcr.io/proxysql/proxysql-operator) is private - ProxySQL/proxysql-on-k8s#83.
#
#   scripts/build-proxysql-operator.sh [version]      # default: 0.7.0
#
# The version must match apps/proxysql-operator/application.yaml's chart
# version (the chart's appVersion is the operator version). Needs: git, go,
# kubectl (pointed at the cluster) and crane (`brew install crane`). No Docker
# daemon: it cross-compiles the manager for linux/arm64 and appends it as one
# layer onto the same distroless base upstream's Dockerfile uses, with the
# same /manager entrypoint and nonroot user (the chart's `command` is
# /manager). Pushes through `kubectl port-forward`, so nothing is exposed.
#
# Set REGISTRY_ADDR to push somewhere else (skips the port-forward).
set -euo pipefail

VERSION="${1:-0.7.0}"
REPO_URL="https://github.com/ProxySQL/proxysql-on-k8s"
BASE_IMAGE="gcr.io/distroless/static:nonroot"
PORT="${PORT:-5000}"
custom_registry="${REGISTRY_ADDR:+1}"
REGISTRY_ADDR="${REGISTRY_ADDR:-localhost:${PORT}}"
IMAGE="${REGISTRY_ADDR}/proxysql-operator:${VERSION}"

for tool in git go crane; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

work="$(mktemp -d)"
pf_pid=""
cleanup() { [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

echo "==> cloning ${REPO_URL} @ proxysql-operator-${VERSION}"
git clone -q --depth 1 --branch "proxysql-operator-${VERSION}" "$REPO_URL" "$work/src"
commit="$(git -C "$work/src" rev-parse --short HEAD)"

echo "==> building manager (linux/arm64)"
( cd "$work/src/operator" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${commit}" \
    -o "$work/manager" cmd/main.go )

echo "==> assembling layer"
mkdir "$work/layer"
install -m 0755 "$work/manager" "$work/layer/manager"
tar -C "$work/layer" -cf "$work/layer.tar" manager

if [ -z "$custom_registry" ]; then
  echo "==> port-forwarding svc/zot to localhost:${PORT}"
  kubectl -n zot port-forward svc/zot "${PORT}:5000" >/dev/null &
  pf_pid=$!
  for _ in $(seq 1 30); do
    curl -fsS "http://localhost:${PORT}/v2/" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "http://localhost:${PORT}/v2/" >/dev/null || { echo "Zot not reachable" >&2; exit 1; }
fi

echo "==> pushing ${IMAGE}"
crane --platform linux/arm64 append \
  --base "$BASE_IMAGE" --new_layer "$work/layer.tar" --new_tag "$IMAGE"
crane mutate "$IMAGE" --platform linux/arm64 \
  --entrypoint /manager --user 65532:65532 \
  --label "org.opencontainers.image.source=${REPO_URL}" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.revision=${commit}" \
  --tag "$IMAGE" >/dev/null

echo "==> done: $(crane digest "$IMAGE")  ${IMAGE}"
echo "Pods pull it as localhost:30500/proxysql-operator:${VERSION}"
