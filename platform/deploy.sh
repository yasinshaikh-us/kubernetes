#!/usr/bin/env bash
# Deploys the platform stack onto the cluster in $KUBECONFIG:
#   metrics-server -> Istio (with a public LoadBalancer gateway) -> cert-manager -> nginx -> Headlamp
# Apps are exposed at https://<app>.$DOMAIN (default: <lb-ip>.nip.io).
#
# Optional:
#   DOMAIN=k8s.example.com   use your own domain; needs a wildcard A record *.k8s.example.com -> LB IP
#   RESERVED_IP=1.2.3.4      pin the load balancer to a Civo reserved IP so the DNS record survives rebuilds
set -euo pipefail
cd "$(dirname "$0")"

ISSUER=${ISSUER:-letsencrypt-prod}   # letsencrypt-prod | letsencrypt-staging | selfsigned
ISTIO_VERSION=1.30.5
CERT_MANAGER_VERSION=v1.21.2
HEADLAMP_VERSION=0.45.0
METRICS_SERVER_VERSION=3.14.0

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

echo "==> metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system --version $METRICS_SERVER_VERSION -f metrics-server/values.yaml --wait

echo "==> Istio"
helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version $ISTIO_VERSION --wait
helm upgrade --install istiod istio/istiod -n istio-system --version $ISTIO_VERSION -f istio/values-istiod.yaml --wait
gateway_args=()
if [ -n "${RESERVED_IP:-}" ]; then
  gateway_args+=(--set-string "service.annotations.kubernetes\.civo\.com/ipv4-address=$RESERVED_IP")
fi
helm upgrade --install istio-ingressgateway istio/gateway -n istio-system --version $ISTIO_VERSION -f istio/values-gateway.yaml "${gateway_args[@]}" --wait

echo "==> Waiting for load balancer IP"
until LB_IP=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}') && [ -n "$LB_IP" ]; do sleep 5; done
export DOMAIN="${DOMAIN:-$LB_IP.nip.io}" ISSUER
echo "    $LB_IP -> *.$DOMAIN"
# Let's Encrypt HTTP-01 fails unless the hostnames resolve to the gateway.
for host in nginx headlamp; do
  resolved=$(getent ahostsv4 "$host.$DOMAIN" | awk 'NR==1{print $1}')
  if [ "$resolved" != "$LB_IP" ]; then
    echo "ERROR: $host.$DOMAIN resolves to '${resolved:-nothing}', expected $LB_IP. Point *.$DOMAIN at $LB_IP." >&2
    exit 1
  fi
done

echo "==> cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version $CERT_MANAGER_VERSION -f cert-manager/values.yaml --wait
kubectl apply -f cert-manager/cluster-issuers.yaml
envsubst < cert-manager/certificate.yaml | kubectl apply -f -
envsubst < istio/gateway.yaml | kubectl apply -f -

echo "==> nginx"
envsubst < nginx/nginx.yaml | kubectl apply -f -
kubectl -n nginx rollout status deploy/nginx --timeout=180s

echo "==> Headlamp"
helm upgrade --install headlamp headlamp/headlamp -n headlamp --create-namespace --version $HEADLAMP_VERSION -f headlamp/values.yaml --wait
kubectl apply -f headlamp/admin-sa.yaml
envsubst < headlamp/virtualservice.yaml | kubectl apply -f -

echo "==> Waiting for TLS certificate"
kubectl -n istio-system wait certificate/public-tls --for=condition=Ready --timeout=300s

cat <<MSG

nginx:     https://nginx.$DOMAIN
Headlamp:  https://headlamp.$DOMAIN
Headlamp token:
  kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
MSG
