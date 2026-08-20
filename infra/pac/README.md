# Phase 1 — PAC Cluster Installation (Vanilla Kubernetes)

Installs the Pipelines as Code (PAC) controller/webhook/watcher on a vanilla
Kubernetes or k3s cluster. Corresponds to Phase 1 of
`topic/20260820-1_init_tekton_cicd_example/20.plan.md`.

## Prerequisites
- `kubectl` installed and pointed at the target cluster's context
  (`kubectl config current-context` should show the right cluster).
- Cluster-admin rights (installs CRDs and a new namespace).

## Steps

1. Install:
   ```bash
   ./install.sh
   ```
   Applies the stable PAC release manifest and waits for the `controller`,
   `webhook`, and `watcher` deployments in the `pipelines-as-code` namespace
   to report Available.

2. Verify:
   ```bash
   ./verify.sh
   ```
   Lists deployments and pods in `pipelines-as-code`; all should be
   `Running`/`1/1`.

## Webhook delivery: real Ingress (decided)

Decision: **real Ingress**, not gosmee. This cluster is already proven
internet-reachable — `tekton-pipelines/tekton-dashboard` runs a working
Ingress on `bless2k.duckdns.org` via the cluster's default Traefik. `ingress.yaml`
adds a second rule on the same host at path `/pac`, routed to the PAC
controller service (port 8080). Traefik prefers the longer path prefix, so
`/pac` reaches the controller and `/` still reaches the dashboard.

Apply it:
```bash
kubectl apply -f ingress.yaml
```

The controller ignores the request path entirely (verified: it returns 200
on `GET`/`POST` to any path), so `/pac` is just a routing choice, not
something the controller itself cares about.

**GitHub App Webhook URL (Phase 2): `https://bless2k.duckdns.org/pac`**

Caveat: no cert-manager is installed, so HTTPS on this host uses Traefik's
default self-signed cert. Either disable "SSL verification" on the GitHub
App (fine for this demo), or provision a real cert before treating this as
more than an example.

## Exit criteria
- `verify.sh` shows all PAC deployments healthy. ✅
- A webhook delivery path is live and externally reachable. ✅ verified
  2026-08-20 via `curl` from outside the cluster:
  `GET/POST https://bless2k.duckdns.org/pac` → `200`;
  `GET http://bless2k.duckdns.org/pac` → `200`;
  dashboard's `GET https://bless2k.duckdns.org/` → `401` (unaffected).

## Status
**Complete.** PAC controller/webhook/watcher are installed and healthy in
the `pipelines-as-code` namespace (confirmed via `kubectl`, connected to the
remote k3s cluster at `bless2k.duckdns.org`). `ingress.yaml` is applied and
externally verified. Ready for Phase 2 (GitHub App creation), using
`https://bless2k.duckdns.org/pac` as the Webhook URL.
