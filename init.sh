#!/usr/bin/env bash
set -euo pipefail

CILIUM_VERSION="1.19.2"
CLUSTER_NAME="kind"

echo "==> Creating Kind cluster (1 control-plane, 2 workers, no default CNI)..."
kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml

echo "==> Setting kubectl context..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

echo "==> Adding Cilium Helm repository..."
helm repo add cilium https://helm.cilium.io/
helm repo update

echo "==> Installing Cilium v${CILIUM_VERSION} via Helm..."
# image.pullPolicy=Always: kind nodes pull directly from the registry.
# kind load docker-image is skipped because Docker Desktop on macOS stores
# images in a VM-internal format; saving a single-arch image and importing it
# with ctr --all-platforms inside the node fails with missing digest errors.
helm install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set image.pullPolicy=Always \
  --set ipam.mode=kubernetes \
  --set hubble.relay.enabled=true

echo "==> Waiting for Cilium pods to be ready..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=120s

echo "==> Cluster nodes status:"
kubectl get nodes

echo ""
echo "Done. Run 'cilium status --wait' to verify the installation."
