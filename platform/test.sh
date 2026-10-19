#!/usr/bin/env bash
# Smoke tests for the platform stack. Exits non-zero if any check fails.
set -uo pipefail

LB_IP=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
DOMAIN="${DOMAIN:-$LB_IP.nip.io}"
fail=0
check() { # name, command...
  local name=$1; shift
  if out=$("$@" 2>&1); then echo "PASS  $name"; else echo "FAIL  $name"; echo "$out" | sed 's/^/      /'; fail=1; fi
}

check "all pods Running/Completed" bash -c \
  "! kubectl get pods -A --no-headers | grep -Ev 'Running|Completed'"
check "metrics API (kubectl top)"  kubectl top nodes
check "istiod ready"                 kubectl -n istio-system rollout status deploy/istiod --timeout=10s
check "gateway has public IP"        test -n "$LB_IP"
check "nginx pods have Istio sidecar" bash -c \
  "kubectl -n nginx get pods -l app=nginx -o jsonpath='{range .items[*]}{.spec.initContainers[*].name} {.spec.containers[*].name}{\"\n\"}{end}' > /tmp/pods && test -s /tmp/pods && ! grep -v istio-proxy /tmp/pods"
check "cert-manager webhook ready"   kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10s
check "trust-manager ready"          kubectl -n cert-manager rollout status deploy/trust-manager --timeout=10s
check "Firefly ready"                kubectl -n venafi rollout status deploy/firefly --timeout=10s
check "Firefly issued its CA probe"  bash -c \
  "kubectl -n cert-manager get certificate firefly-ca -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
check "istio-csr ready"              kubectl -n cert-manager rollout status deploy/cert-manager-istio-csr --timeout=10s
check "trust bundle in every namespace" bash -c \
  "for ns in \$(kubectl get ns -o name | cut -d/ -f2); do kubectl -n \$ns get cm workload-trust-bundle >/dev/null || exit 1; done"
check "workloads + workspaces pods have sidecars" bash -c \
  "for ns in workloads workspaces; do kubectl -n \$ns get pods -o jsonpath='{range .items[*]}{.spec.initContainers[*].name} {.spec.containers[*].name}{\"\n\"}{end}'; done > /tmp/wl && test \$(wc -l < /tmp/wl) -ge 4 && ! grep -v istio-proxy /tmp/wl"
check "mesh certs signed by Firefly" bash -c \
  "kubectl -n istio-system get certificaterequests -o json | jq -e '
     [.items[] | select(.spec.issuerRef.group == \"firefly.venafi.com\")
              | select(any(.status.conditions[]?; .type == \"Ready\" and .status == \"True\"))] | length > 0' >/dev/null"
check "workload SVIDs chain to the trust bundle" bash -c \
  "kubectl -n cert-manager get cm workload-trust-bundle -o jsonpath='{.data.ca\\.crt}' > /tmp/bundle.pem && \
   kubectl -n istio-system get certificaterequests -o json | jq -r '
     [.items[] | select(.spec.issuerRef.group == \"firefly.venafi.com\") | select(.status.certificate)
               ][-1].status.certificate' | base64 -d > /tmp/svid.pem && \
   openssl verify -CAfile /tmp/bundle.pem -untrusted /tmp/svid.pem /tmp/svid.pem"
check "workspace -> httpbin over STRICT mTLS" bash -c \
  "for p in \$(kubectl -n workspaces get pods -l app=workspace -o name); do \
     kubectl -n workspaces exec \$p -c workspace -- curl -fsS http://httpbin.workloads:8000/headers | grep -q 'spiffe://cluster.local/ns/workspaces/sa/workspace' || exit 1; done"
check "plaintext from outside the mesh is rejected" bash -c \
  "! kubectl run mtls-probe-\$RANDOM -n default --rm -i --restart=Never --quiet --image=curlimages/curl:8.16.0 -- \
     curl -fsS -m 5 http://httpbin.workloads:8000/get"
check "certificate issued"           bash -c \
  "kubectl -n istio-system get certificate public-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
check "nginx over HTTP"              bash -c "curl -fsS http://nginx.$DOMAIN | grep -q 'Welcome to nginx'"
check "nginx over HTTPS (valid cert)" bash -c "curl -fsS https://nginx.$DOMAIN | grep -q 'Welcome to nginx'"
check "Headlamp over HTTPS"          bash -c "curl -fsS https://headlamp.$DOMAIN | grep -qi headlamp"
check "Headlamp token can list nodes" bash -c \
  "TOKEN=\$(kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d); \
   kubectl --token=\"\$TOKEN\" get nodes >/dev/null"

exit $fail
