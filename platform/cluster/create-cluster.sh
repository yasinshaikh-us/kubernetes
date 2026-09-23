#!/usr/bin/env bash
# Creates a small Civo k3s cluster, or reuses one with the same name, and writes its kubeconfig.
# Needs CIVO_TOKEN. The nightly cleanup workflow deletes every cluster at 1:00 AM Pacific.
set -euo pipefail

NAME=${NAME:-sandbox}
REGION=${REGION:-nyc1}
SIZE=${SIZE:-g4s.kube.small}   # 1 vCPU / 2 GB
NODES=${NODES:-3}
K8S_VERSION=${K8S_VERSION:-1.35.0-k3s1}
KUBECONFIG_OUT=${KUBECONFIG_OUT:-./kubeconfig}
API=https://api.civo.com/v2

api() { curl -sS --fail-with-body --retry 3 -H "Authorization: Bearer ${CIVO_TOKEN:?CIVO_TOKEN not set}" "$@"; }

id=$(api "$API/kubernetes/clusters?region=$REGION&per_page=100" | jq -r --arg n "$NAME" '.items[]? | select(.name == $n) | .id' | head -1)

if [ -n "$id" ]; then
  echo "Reusing cluster $NAME ($id) in $REGION"
else
  network_id=$(api "$API/networks?region=$REGION" | jq -r '.[] | select(.default) | .id')
  id=$(api -X POST "$API/kubernetes/clusters" -H 'Content-Type: application/json' -d @- <<JSON | jq -r .id
{
  "name": "$NAME", "region": "$REGION", "network_id": "$network_id",
  "kubernetes_version": "$K8S_VERSION", "cluster_type": "k3s", "cni_plugin": "flannel",
  "pools": [{"id": "default", "size": "$SIZE", "count": $NODES}],
  "create_firewall": true, "firewall_rule": "6443,80,443"
}
JSON
  )
  echo "Creating cluster $NAME ($id) in $REGION"
fi

until [ "$(api "$API/kubernetes/clusters/$id?region=$REGION" | jq -r .status)" = "ACTIVE" ]; do sleep 15; done
api "$API/kubernetes/clusters/$id?region=$REGION" | jq -r .kubeconfig > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"
until KUBECONFIG=$KUBECONFIG_OUT kubectl get nodes >/dev/null 2>&1; do sleep 5; done
KUBECONFIG=$KUBECONFIG_OUT kubectl wait node --all --for=condition=Ready --timeout=300s
echo "Cluster ready. export KUBECONFIG=$KUBECONFIG_OUT"
