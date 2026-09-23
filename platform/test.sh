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
check "certificate issued"           bash -c \
  "kubectl -n istio-system get certificate public-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"
check "nginx over HTTP"              bash -c "curl -fsS http://nginx.$DOMAIN | grep -q 'Welcome to nginx'"
check "nginx over HTTPS (valid cert)" bash -c "curl -fsS https://nginx.$DOMAIN | grep -q 'Welcome to nginx'"
check "Headlamp over HTTPS"          bash -c "curl -fsS https://headlamp.$DOMAIN | grep -qi headlamp"
check "Headlamp token can list nodes" bash -c \
  "TOKEN=\$(kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d); \
   kubectl --token=\"\$TOKEN\" get nodes >/dev/null"

exit $fail
