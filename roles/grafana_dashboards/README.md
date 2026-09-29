# Grafana Dashboards Role

Imports community dashboards from grafana.com into `apps/victoria-metrics`'s Grafana, over its Tailscale
Operator ingress — no manual "Dashboards → Import → paste ID" clicking required.

## What It Does

For each entry in `grafana_community_dashboards` (see `defaults/main.yml`):
1. Downloads that dashboard's JSON from `https://grafana.com/api/dashboards/<id>/revisions/latest/download`.
2. Substitutes its `${DS_XXX}` datasource placeholder(s) for this cluster's actual default datasource UID
   (looked up live via `GET /api/datasources` — currently `VictoriaMetrics`, the Prometheus-compatible
   datasource pointed at `vmsingle`).
3. Posts the result to this Grafana's `POST /api/dashboards/db`, `overwrite: true` — safe to re-run, it just
   updates the same dashboards to whatever grafana.com currently serves for that ID.

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

| Dashboard | grafana.com ID |
|---|---|
| Longhorn | 22705 |
| CloudNativePG | 20417 |
| Temporal Server Metrics | 20528 |
| Redis (Kubernetes mode) | 19157 |
| Blocky | 13768 |
| VictoriaMetrics vmagent | 12683 |
| VictoriaMetrics Single Node | 10229 |

Kubernetes cluster/node views, CoreDNS, etcd, Node Exporter Full, and all four VictoriaMetrics dashboards
(operator, vmalert, vmagent, single-node) are **not** in this list — confirmed live via `GET /api/search`
that `apps/victoria-metrics`'s `defaultDashboards` already provisions all of them (tagged `vm-k8s-stack`),
not just the two (`victoriametrics-operator`, `victoriametrics-vmalert`) explicitly toggled in
`apps/victoria-metrics/values.yaml` — the chart's own remaining defaults were already enabled. Re-adding
one of their grafana.com IDs here would `400` (`"Cannot save provisioned dashboard"`, Grafana refuses to
let the API touch a ConfigMap-provisioned dashboard) — `tasks/import_dashboard.yml` treats that specific
error as a skip rather than a failure, so this is a safety net, not a reason to rely on it.

Deliberately excludes Argo CD and the Tailscale operator — dashboards exist for both on grafana.com, but
neither has a `VM*Scrape` wired up in this repo yet, so importing them would just show empty panels. Add
their IDs here once that scrape config exists.

## Usage

```bash
ansible-playbook site.yml -i inventory.dist --tags grafana
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
