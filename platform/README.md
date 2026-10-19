# Platform stack

Components deployed onto a small Civo k3s sandbox (3 × `g4s.kube.medium`, 2 vCPU / 4 GB each) and smoke-tested.

| Folder | Component | How it's installed | What gets tested |
|---|---|---|---|
| `cluster/` | Civo k3s cluster | Civo API (`create-cluster.sh`) | Nodes Ready |
| `metrics-server/` | metrics-server 3.14.0 | Helm | `kubectl top nodes` works (Headlamp CPU/memory graphs) |
| `istio/` | Istio 1.30.5: base, istiod, ingress gateway | Helm + `gateway.yaml` | istiod ready, gateway gets a public LoadBalancer IP, sidecar injection |
| `cert-manager/` | cert-manager v1.21.2 + issuers (Let's Encrypt prod/staging, self-signed) | Helm + manifests | Let's Encrypt cert issued via HTTP-01 through the Istio gateway |
| `trust-manager/` | trust-manager v0.25.0 + `Bundle` | Helm + manifest | Firefly CA copied to every namespace as ConfigMap `workload-trust-bundle` |
| `firefly/` | CyberArk Workload Identity Manager (Firefly) v1.12.0 | Helm (public OCI chart) | Runs as a cert-manager issuer (`firefly.venafi.com`) and signs a probe cert |
| `istio-csr/` | cert-manager istio-csr v0.18.0 | Helm | Mesh CA for istiod and every sidecar; CSRs become CertificateRequests signed by Firefly |
| `workloads/` | 2 × httpbin (`workloads`), 2 × workspace (`workspaces`), STRICT mTLS | Plain manifests | Workspace → httpbin over mTLS with Firefly-issued SPIFFE certs; plaintext rejected |
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

## Workload identity (Firefly + istio-csr + trust-manager)

```
istio-agent (sidecar) --CSR--> istio-csr --CertificateRequest--> cert-manager --approve--> Firefly --signs--> SVID
                                   ^ root of trust: ConfigMap workload-trust-bundle (trust-manager, from Firefly's CA)
```

istiod's built-in CA is off (`ENABLE_CA_SERVER=false`); sidecars and gateways use `cert-manager-istio-csr.cert-manager.svc:443`. Every request carries the annotation `firefly.venafi.com/policy-name: istio-mesh`, so Firefly applies that policy. Signed requests are kept in `istio-system` for inspection: `kubectl -n istio-system get certificaterequests`.

Firefly has two bootstrap modes:

- **Venafi / CyberArk Certificate Manager SaaS** (used when the repo secrets `VENAFI_CLIENT_ID` and `VENAFI_PRIVATE_KEY` exist). Firefly authenticates with the service account key, gets its issuing intermediate from the SaaS sub-CA, and pulls policies from its Firefly configuration. One-time setup in the SaaS tenant:
  1. Create an API key (Account → Preferences).
  2. Create a Firefly service account: `venctl iam service-accounts firefly create --name sandbox-firefly --output secret --output-file firefly-sa.json --api-key $API_KEY`. Save `client_id` as `VENAFI_CLIENT_ID` and `private_key` as `VENAFI_PRIVATE_KEY`.
  3. In the console, create a sub-CA provider, a policy named `istio-mesh` (allow URI SANs `spiffe://cluster.local/.*`, DNS SANs, EC P-256 and RSA 2048, server + client auth), and a Firefly configuration that uses them and is assigned to the service account.
- **Self-signed dev mode** (no Venafi secrets). Firefly creates an in-memory CA and uses the `istio-mesh` policy from `firefly/values-selfsigned.yaml`. One replica only; restarting Firefly creates a new CA, so redeploy after a restart.

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
