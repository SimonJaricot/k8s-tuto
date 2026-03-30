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
# Options activées :
#   kubeProxyReplacement=true  : remplace kube-proxy par Cilium (requis pour Gateway API)
#   gatewayAPI.enabled=true    : active le support de la Gateway API (module 09)
#   l2announcements.enabled=true : active les annonces L2 pour les IPs LoadBalancer (module 09)
#   hubble.relay.enabled=true  : active Hubble pour l'observabilité (module 10)
#
# image.pullPolicy=Always : kind nodes pull directement depuis le registry.
# "kind load docker-image" est ignoré car Docker Desktop sur macOS stocke les images
# dans un format VM-interne ; l'import avec ctr --all-platforms échoue (missing digest).
helm install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set image.pullPolicy=Always \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true \
  --set hubble.relay.enabled=true

echo "==> Waiting for Cilium pods to be ready..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=180s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=120s

echo "==> Cluster nodes status:"
kubectl get nodes

echo ""
echo "Done. Run 'cilium status --wait' to verify the installation."
