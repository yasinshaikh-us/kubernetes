# Platform stack

Components deployed onto a small Civo k3s sandbox (3 × `g4s.kube.small`, 1 vCPU / 2 GB each) and smoke-tested.

| Folder | Component | How it's installed | What gets tested |
|---|---|---|---|
| `cluster/` | Civo k3s cluster | Civo API (`create-cluster.sh`) | Nodes Ready |
| `metrics-server/` | metrics-server 3.14.0 | Helm | `kubectl top nodes` works (Headlamp CPU/memory graphs) |
| `istio/` | Istio 1.30.5: base, istiod, ingress gateway | Helm + `gateway.yaml` | istiod ready, gateway gets a public LoadBalancer IP, sidecar injection |
| `cert-manager/` | cert-manager v1.21.2 + issuers (Let's Encrypt prod/staging, self-signed) | Helm + manifests | Let's Encrypt cert issued via HTTP-01 through the Istio gateway |
| `nginx/` | nginx (2 replicas, in the mesh) | Plain manifests | `http://` and `https://nginx.<ip>.nip.io` |
| `headlamp/` | Headlamp 0.45.0 web UI + admin ServiceAccount | Helm + manifests | UI reachable over HTTPS, token can talk to the API |

Resource requests are trimmed so everything fits on the small nodes. Istio's chart defaults alone ask for 2 GB.

## Traffic flow

```
Internet -> Civo LoadBalancer -> istio-ingressgateway (Gateway "public", TLS from cert-manager)
                                   |-> nginx.<ip>.nip.io     -> nginx/nginx (with Envoy sidecar)
                                   |-> headlamp.<ip>.nip.io  -> headlamp/headlamp
```

`nip.io` resolves `<anything>.<ip>.nip.io` to `<ip>`, so no DNS setup is needed.

## Using your own domain

Some networks block `nip.io`. To use a domain you control instead:

1. Reserve an IP in Civo (Networking → Reserved IPs, same region as the cluster). Save it as the repo variable `CIVO_RESERVED_IP`. The load balancer is pinned to that IP, so it stays the same when the nightly cleanup rebuilds the cluster.
2. Create a DNS record `*.k8s.example.com  A  <reserved ip>`.
3. Save `k8s.example.com` as the repo variable `PLATFORM_DOMAIN`, or pass it as the `domain` input when you run the workflow.

Before requesting certificates, `deploy.sh` checks that the hostnames resolve to the load balancer. If they don't, it stops with an error.

## Run it

Use the **Platform deploy** GitHub Action (Actions tab → Run workflow). It creates the `sandbox` cluster, or reuses it if it exists, then deploys and tests. PRs that touch `platform/` run the same deploy and tests.

To run it from your machine instead:

```sh
export CIVO_TOKEN=...
platform/cluster/create-cluster.sh && export KUBECONFIG=$PWD/kubeconfig
platform/deploy.sh      # optional: DOMAIN=..., RESERVED_IP=..., ISSUER=selfsigned
platform/test.sh
```

## Headlamp login

Headlamp asks for a token. With the cluster's kubeconfig (Civo dashboard → cluster → Download kubeconfig):

```sh
kubectl -n headlamp get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d
```

This repo is public, so the workflow never prints the token in plain text. If you pass an `age` public key as the `age_recipient` input, it prints the token encrypted to that key.

The nightly **Civo cluster cleanup** workflow deletes the cluster at 1:00 AM Pacific.
