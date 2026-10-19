#!/usr/bin/env bash
# Deploys the platform stack onto the cluster in $KUBECONFIG:
#   metrics-server -> cert-manager -> trust-manager -> Firefly -> istio-csr -> Istio (public gateway)
#   -> test workloads -> nginx -> Headlamp
# Mesh certificates: istio-agent -> istio-csr -> cert-manager CertificateRequest -> Firefly signs.
# Apps are exposed at https://<app>.$DOMAIN (default: <lb-ip>.nip.io).
#
# Optional:
#   DOMAIN=k8s.example.com   use your own domain; needs a wildcard A record *.k8s.example.com -> LB IP
#   RESERVED_IP=1.2.3.4      pin the load balancer to a Civo reserved IP so the DNS record survives rebuilds
#   VENAFI_CLIENT_ID=...     Firefly service account from Venafi / CyberArk Certificate Manager SaaS, plus
#   VENAFI_PRIVATE_KEY=...   its PEM private key. Without both, Firefly runs in self-signed dev mode.
set -euo pipefail
cd "$(dirname "$0")"

ISSUER=${ISSUER:-letsencrypt-prod}   # letsencrypt-prod | letsencrypt-staging | selfsigned
ISTIO_VERSION=1.30.5
CERT_MANAGER_VERSION=v1.21.2
HEADLAMP_VERSION=0.45.0
METRICS_SERVER_VERSION=3.14.0
TRUST_MANAGER_VERSION=v0.25.0
ISTIO_CSR_VERSION=v0.18.0
FIREFLY_VERSION=v1.12.0

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

echo "==> metrics-server"
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system --version $METRICS_SERVER_VERSION -f metrics-server/values.yaml --wait

echo "==> cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version $CERT_MANAGER_VERSION -f cert-manager/values.yaml --wait

echo "==> trust-manager"
helm upgrade --install trust-manager jetstack/trust-manager -n cert-manager --version $TRUST_MANAGER_VERSION -f trust-manager/values.yaml --wait

echo "==> Firefly"
kubectl create namespace venafi --dry-run=client -o yaml | kubectl apply -f -
firefly_args=(-f firefly/values.yaml)
if [ -n "${VENAFI_CLIENT_ID:-}" ] && [ -n "${VENAFI_PRIVATE_KEY:-}" ]; then
  echo "    bootstrap: Venafi Certificate Manager SaaS"
  kubectl -n venafi create secret generic venafi-credentials --from-literal=svc-acct.key="$VENAFI_PRIVATE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  firefly_args+=(-f firefly/values-venafi.yaml --set-string "deployment.config.bootstrap.vaas.clientID=$VENAFI_CLIENT_ID")
else
  echo "    bootstrap: self-signed dev mode (set VENAFI_CLIENT_ID and VENAFI_PRIVATE_KEY to use Venafi)"
  firefly_args+=(-f firefly/values-selfsigned.yaml)
fi
# The chart doesn't roll the pod when its ConfigMap changes; an env var holding the config hash does.
config_hash=$(for a in "${firefly_args[@]}"; do if [ -f "$a" ]; then cat "$a"; else echo "$a"; fi; done | sha256sum | cut -c1-16)
firefly_args+=(--set "deployment.extraEnv[0].name=CONFIG_HASH" --set-string "deployment.extraEnv[0].value=$config_hash")
helm upgrade --install firefly oci://registry.venafi.cloud/public/venafi-images/helm/firefly -n venafi --version $FIREFLY_VERSION "${firefly_args[@]}" --wait
kubectl apply -f firefly/ca-probe.yaml
kubectl -n cert-manager wait certificate/firefly-ca --for=condition=Ready --timeout=120s
kubectl apply -f trust-manager/bundle.yaml
until kubectl -n cert-manager get configmap workload-trust-bundle >/dev/null 2>&1; do sleep 2; done

echo "==> istio-csr"
# istio-csr needs the istio-system namespace and must be serving before istiod starts.
helm upgrade --install istio-base istio/base -n istio-system --create-namespace --version $ISTIO_VERSION --wait
helm upgrade --install cert-manager-istio-csr jetstack/cert-manager-istio-csr -n cert-manager --version $ISTIO_CSR_VERSION -f istio-csr/values.yaml --wait

echo "==> Istio"
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

kubectl apply -f cert-manager/cluster-issuers.yaml
envsubst < cert-manager/certificate.yaml | kubectl apply -f -
envsubst < istio/gateway.yaml | kubectl apply -f -

echo "==> Test workloads"
kubectl apply -f workloads/workloads.yaml
kubectl -n workloads rollout status deploy/httpbin --timeout=180s
kubectl -n workspaces rollout status deploy/workspace --timeout=180s

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
