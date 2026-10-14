# Grafana Dashboards Role

Imports community dashboards from grafana.com into `apps/victoria-metrics`'s Grafana, over its Tailscale
Operator ingress — no manual "Dashboards → Import → paste ID" clicking required.

## What It Does

For each entry in `grafana_community_dashboards` (see `defaults/main.yml`):
1. Downloads that dashboard's JSON from `https://grafana.com/api/dashboards/<id>/revisions/latest/download`.
2. Substitutes its `${DS_XXX}` datasource placeholder(s) for this cluster's actual default datasource UID
   (looked up live via `GET /api/datasources` — currently `VictoriaMetrics`, the Prometheus-compatible
   datasource pointed at `vmselect`).
3. Looks the dashboard up in Grafana by `uid` and decides what to do (below). Only a dashboard that needs it is written,
   via `POST /api/dashboards/db`.

## Re-runs: what it writes and what it leaves alone

The role does not blindly overwrite. Each save it makes adds one tag to the dashboard,
`ansible:<fingerprint>@v<version>` - a fingerprint of exactly what was posted (so it changes when grafana.com publishes a
new revision or the default datasource changes) and the dashboard version that save produced. The next run reads it back:

| Situation | Result |
|---|---|
| dashboard does not exist | **created** |
| still at the version in the tag, same fingerprint | **unchanged** - nothing is written |
| still at the version in the tag, different fingerprint | **updated** (grafana.com or the datasource changed) |
| saved again in Grafana since (version moved past the tag) | **left alone and reported** - someone edited it |
| provisioned by the VictoriaMetrics chart | **skipped** (Grafana refuses API writes to those) |
| exists but has no tag (imported by an older version of this role) | **adopted once**, which writes the tag |

A run ends with a summary of which dashboards fell in each bucket. Two switches (`defaults/main.yml`):
`-e grafana_dashboards_overwrite_edited=true` replaces dashboards that were edited in Grafana (their edits are lost), and
`-e grafana_dashboards_force=true` re-imports everything regardless. `--check` shows the real decisions and writes nothing.

Why the state is a tag and not the save message: verified against Grafana 13.1.1 that a save bumps `version` by exactly one,
that Grafana ignores a save whose content is identical to what is stored (so a second "stamp" save never lands), and that a
newly created dashboard's first version is always "Initial save" whatever message was sent. The tag shows on the dashboard
as a small chip; removing it makes the next run treat the dashboard as an unmanaged import.

Duplicate protection rests on `uid`: Grafana matches a re-import to the existing dashboard by it. Most grafana.com dashboards
carry one; those that do not (OpenSearch Prometheus Exporter, id 20827) get a fixed `gcom-<id>` so they are matched too.
Dashboards removed from `grafana_community_dashboards` are not deleted from Grafana.

## Why `/api/dashboards/db` and not `/api/dashboards/import`

The UI's own Import wizard calls `/api/dashboards/import`, but Grafana has never published a schema for
it ([grafana/grafana#7029](https://github.com/grafana/grafana/issues/7029) — 2015, still open). `/api/dashboards/db`
is the documented endpoint, confirmed live against this cluster's actual Grafana 13.1.1: it still works fully
(Grafana 13 only logs a deprecation warning pointing at the newer `/apis/dashboard.grafana.app/v1` API, which
requires a service account Bearer token — a needless dependency here since `/api/dashboards/db` needs none).

## Why no credentials

`apps/victoria-metrics/values.yaml` gives anonymous requests `org_role: Admin`
(`auth.anonymous.enabled: true`) — confirmed live, every call this role makes succeeds unauthenticated.
If anonymous Admin access is ever turned off, this role will need a service account token added to its
`uri` tasks (`headers: Authorization: Bearer ...`).

## Dashboard List

Limited to tech this cluster actually scrapes today (see each app's `manifests/vm*scrape.yaml` — `vmagent`
picks up every `VMServiceScrape`/`VMPodScrape` in the cluster automatically):

| Dashboard | grafana.com ID | Covers |
|---|---|---|
| Longhorn; Longhorn Monitoring & Backups | 22705; 16888 | volumes, replicas, nodes, backups |
| CloudNativePG | 20417 | Postgres instances (not the poolers - see below) |
| Temporal Server Metrics | 20528 | Temporal services |
| Redis (Kubernetes mode); Redis Dashboard for Prometheus Redis Exporter 1.x | 19157; 763 | the three caches |
| Redis Sentinel | 9570 | the shared Sentinel (needs its exporter sidecar) |
| Blocky | 13768 | DNS |
| ArgoCD Operational; ArgoCD Application | 19993; 19974 | Argo CD |
| OpenSearch Prometheus Exporter | 20827 | OpenSearch cluster |
| Trivy Operator (Image CVE Data; Vulnerabilities) | 22010; 16337 | vulnerability reports |
| Zot | 20501 | the registry cache |

Written for this repo and provisioned as ConfigMaps (`apps/victoria-metrics/manifests/`), because no community
dashboard matches the metric names: **PgBouncer (CloudNativePG poolers)** (`cnpg_pgbouncer_*`) and **Vector**
(`vector_*`).

**No dashboard**, because nothing useful exists or the app exposes no metrics worth one: Bifrost, SearXNG,
go-feature-flag, the redis-operator controller, descheduler, Headlamp, WhoDB, Open WebUI, Homepage,
shairport-sync, Tailscale (the community dashboard polls the admin API, not the proxies' `/metrics`).
etcd, the scheduler and the controller manager are scraped (k3s exposes them via `group_vars/server/main.yaml`; the targets are the three servers' LAN IPs in `apps/victoria-metrics/manifests/control-plane-scrapes.yaml`), so the chart's etcd, scheduler and controller-manager dashboards fill in once the servers have been restarted with those settings.

Kubernetes cluster/node views, CoreDNS, etcd, Node Exporter Full, and all four VictoriaMetrics dashboards
(operator, vmalert, vmagent, single-node) are **not** in this list — confirmed live via `GET /api/search`
that `apps/victoria-metrics`'s `defaultDashboards` already provisions all of them (tagged `vm-k8s-stack`),
not just the two (`victoriametrics-operator`, `victoriametrics-vmalert`) explicitly toggled in
`apps/victoria-metrics/values.yaml` — the chart's own remaining defaults were already enabled. Re-adding
one of their grafana.com IDs here would `400` (`"Cannot save provisioned dashboard"`, Grafana refuses to
let the API touch a ConfigMap-provisioned dashboard) — `tasks/import_dashboard.yml` treats that specific
error as a skip rather than a failure, so this is a safety net, not a reason to rely on it.

## Usage

```bash
make deploy-dashboards   # same as: ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags dashboards
```

Runs from the Ansible control host (`hosts: localhost` — no Pi/kubectl access needed, this is pure HTTP),
which must itself be joined to the tailnet and able to resolve `grafana.{{ tailnet_domain }}` (see
`group_vars/all/main.yaml`).

## Dependencies

- `tailnet_domain` set in `group_vars/all/main.yaml`.
- `apps/victoria-metrics` already synced by Argo CD (Grafana pod `Ready`).
- Control host on the tailnet with working MagicDNS.

## Adding a dashboard

Add `{ id: <grafana.com id>, name: "<label>" }` to `grafana_community_dashboards` in `defaults/main.yml`.
Only add dashboards for tech that's already being scraped — check for a `VM*Scrape` object in that app's
`manifests/` first, otherwise the import will succeed but every panel will be empty.
