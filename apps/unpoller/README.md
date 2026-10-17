# unpoller - UniFi telemetry from the UDM into VictoriaMetrics

UnPoller logs in to the UniFi Network application on the UDM (`https://192.168.1.1`) and serves what it reads as Prometheus
metrics on `:9130/metrics` (prefix `unpoller_`). vmagent scrapes it via `manifests/vmservicescrape.yaml`. Reference:
`docs/REFERENCE.md`, "UniFi telemetry (UnPoller)".

## Checked locally before this was committed

Run the pinned image (`ghcr.io/unpoller/unpoller:v5.5.1`, arm64) in a throwaway pod on rpi-5-4 with this app's exact environment,
non-root, read-only root filesystem, all capabilities dropped, and a dead controller address:
- it accepts every `UP_*` setting: "Prometheus is enabled", "scrape cache enabled, refresh interval: 30s",
  "Prometheus exported at http://0.0.0.0:9130/ - namespace: unpoller"; InfluxDB and Loki are not started;
- `/metrics` answers (HTTP 200) even while the controller is unreachable, and it retries every 30 s;
- without `UP_UNIFI_DEFAULT_TIMEOUT` it hangs forever on an unreachable controller before opening the port (now set to 30s);
- all five dashboards (grafana.com 11311, 11313, 11312, 11314, 11315) import with the same single `DS_PROMETHEUS` input the
  import role already handles, and query `unpoller_*` series.
- the values render against app-template 5.3.0 (checked inside the cluster, on Argo CD's repo-server, because the laptop's Helm fetch of
  the chart repository kept timing out): a Deployment, a Service with a port named `metrics` (what the VMServiceScrape selects) and a
  ServiceAccount; `envFrom` the `unpoller-credentials` Secret; the security context and probes as intended.
Not checked: a real login to the UDM (needs the credential).

## Checklist for tonight

1. **On the UDM**: UniFi Network > Settings > Control Plane > Integrations > create an API key named `unpoller`; copy it (shown once).
   If your firmware has no API keys: create a local admin (Settings > Admins & Users) with a read-only role, "Restrict to local access
   only", access to all sites; then change the Secret entry in `group_vars/all/cluster_secrets.yaml` to
   `UP_UNIFI_DEFAULT_USER` / `UP_UNIFI_DEFAULT_PASS`.
2. **Vault it**: `printf '%s' '<key>' | ansible-vault encrypt_string --stdin-name unifi_poller_api_key`, paste into `group_vars/all/main.yaml`.
3. **Seed the Secret** (also creates the namespace): `make deploy-secrets`.
4. **Push**: `git push`. (The `unpoller` namespace is already allowed in the live Argo project; `make deploy-argocd` later makes the
   Ansible-managed copy match.) Refresh Argo: `kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite`.
5. **Check the pod**: `kubectl -n unpoller get pods`, then `kubectl -n unpoller logs deploy/unpoller` - look for "Polling UniFi Controller" /
   no `[ERROR] ... Auth` lines. A 401/403 means a wrong or under-privileged key.
6. **Check the data** (Grafana > Explore, or `kubectl -n monitoring port-forward svc/vmselect-ui 18481:8481`):
   `count({__name__=~"unpoller_.*"})`, `unpoller_site_users`, `unpoller_device_info`, `up{job=~".*unpoller.*"}`.
7. **Dashboards**: `make deploy-dashboards`.

## Tuning

- Per-client deep packet inspection: set `UP_UNIFI_DEFAULT_SAVE_DPI: "true"` in `values.yaml` (about 150 extra series per client) and
  add grafana.com 11310 to `roles/grafana_dashboards/defaults/main.yml`.
- If the UDM's address changes: `UP_UNIFI_DEFAULT_URL` in `values.yaml` and the `ipBlock` in `manifests/networkpolicy.yaml`.
- PDUs: grafana.com 23027 if you have UniFi PDUs.
