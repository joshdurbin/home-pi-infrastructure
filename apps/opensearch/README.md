# OpenSearch

Replaces `apps/victoria-logs/` as this cluster's log store - same Vector DaemonSet shipping every
container's logs plus host journald, now landing in OpenSearch + OpenSearch Dashboards instead of
VictoriaLogs. Evaluation-scale, single-replica-per-pool deployment, not a production topology.

**Not Kibana** - Elastic revoked Kibana's OSS license in 2021; OpenSearch forked it into a
separately-maintained product called OpenSearch Dashboards. Same job, different name.

## Operator, not a plain chart

Managed by the **OpenSearch Kubernetes Operator** (`opensearch-project/opensearch-k8s-operator`), not the
plain `opensearch`/`opensearch-dashboards` Helm charts an earlier version of this app used directly -
switched to match how the rest of this repo handles stateful/complex apps (Longhorn, `cloudnative-pg`
for Postgres, `redis-operator`, `victoria-metrics-operator`), all operator-managed rather than bare
charts.

**Two Argo CD Applications, not one** - `apps/opensearch/application.yaml` (`opensearch-operator`, sync-wave
1) installs just the operator and its CRDs (`installCRDs: true` by default); `apps/opensearch/cluster/application.yaml`
(`opensearch`, sync-wave 2) installs Vector plus the custom resources that use those CRDs. Confirmed live
this split is load-bearing, not stylistic: Argo CD does a discoverability pre-check across an entire
Application's manifests before syncing anything, which fails on `opensearch.org/v1` if a custom resource
using it is bundled in the *same* Application as the CRD that would create it - `kubectl get crd` stayed
empty and every sync attempt failed with `failed to discover server resources for group version
opensearch.org/v1` until this was split. Sync-waves *within* one Application don't solve it (the
pre-check runs before wave-based ordering starts); ordering *between* two Applications does, since the
root app-of-apps won't even create the wave-2 Application until wave-1's is Synced+Healthy.

Everything OpenSearch-specific is a custom resource in `apps/opensearch/manifests/`, reconciled by the
operator:

- **`cluster.yaml`** (`OpenSearchCluster`) - the cluster itself: two node pools (`client`:
  cluster-manager + coordinating, no PVC; `data`: the only pool with a PVC,
  `storageClassName: longhorn`), plus a `dashboards` section (Dashboards is part of this same custom
  resource under the operator, not a separate chart/release).
- **`ism-policy.yaml`** (`OpenSearchISMPolicy`) - the retention policy, replacing a hand-rolled curl Job
  an earlier version of this app used.
- **`index-template.yaml`** (`OpenSearchIndexTemplate`) - `number_of_replicas: 0` for `logs-*` indices,
  same reason the Job used to set it: this cluster runs a single data node, so a replica shard could
  never be allocated a home.

All three custom resources were validated against the operator's own bundled CRD schemas
(`opensearch.org_opensearchclusters.yaml` etc., extracted from the chart) with `jsonschema` before being
committed - not just guessed from examples.

## Security: mandatory here, unlike everywhere else in this cluster

Every other UI in this cluster relies on Tailscale as the access boundary rather than in-app auth
(Grafana's anonymous Admin, Argo CD via tailnet) - deliberately **not** the case here. Confirmed via the
operator's own forum/docs: there is no equivalent of the plain chart's `DISABLE_SECURITY_PLUGIN=true` for
an `OpenSearchCluster` - TLS is effectively mandatory on the cluster itself (`security.tls.http.generate`
/ `security.tls.transport.generate: true` in `cluster.yaml`, operator-generated self-signed certs), and
the security plugin's own auth comes with it (an `admin`/`password` credential pair, not just certs).

- **`opensearch_admin_password`** (Vault, `group_vars/all/main.yaml`) + a fixed `opensearch_admin_username: admin`
  (`group_vars/all/cluster_secrets.yaml`, non-secret) are seeded into an `opensearch-admin-credentials`
  Secret by `k8s_secrets`. `cluster.yaml`'s `security.config.adminCredentialsSecret` and
  `dashboards.opensearchCredentialsSecret` both reference it, and so does
  `apps/opensearch/values-vector.yaml`'s Vector config (via `envFrom` + `${username}`/`${password}`
  interpolation in its sink `auth` blocks) - one credential, three consumers.
- **Dashboards' own TLS is independently toggleable** from the cluster's (confirmed via the CRD schema:
  `dashboards.tls.enable` is a separate field from `security.tls.http.enabled`) - kept **off**
  (`tls.enable: false`), since Tailscale still terminates TLS for browser access here, same as every
  other UI. Dashboards still authenticates to the (TLS+auth-secured) OpenSearch backend behind it using
  the same credentials Secret - that leg isn't optional.
- **Vector** trusts the operator's self-signed cert (`tls.verify_certificate: false` - there's no real
  CA here, and nothing outside the cluster ever talks to `https://opensearch:9200` directly) and
  authenticates with basic auth over that TLS connection.

## Retention: 48h, matching VictoriaLogs

VictoriaLogs' `retentionPeriod: 48h` is enforced by `manifests/ism-policy.yaml`'s `min_index_age: 2d`
transition to a `delete` state, at daily-index granularity (`logs-%Y.%m.%d` / `logs-host-%Y.%m.%d` -
`values-vector.yaml`'s `bulk.index`). Worth knowing: this is index-boundary granularity, not an exact 48h
cutoff like VictoriaLogs had - data can live up to ~72h in the worst case at daily boundaries.

## Log shipping

Reuses this cluster's existing Vector DaemonSet rather than introducing a new shipper (Fluent Bit is the
more common default for k8s→OpenSearch specifically, but Vector's `elasticsearch` sink is
[documented as fully OpenSearch-compatible](https://vector.dev/docs/reference/configuration/sinks/elasticsearch/),
and this cluster already runs it). Sourced from Vector's own chart (`https://helm.vector.dev`) rather
than `victoria-logs-single`'s bundled `vector` subchart dependency, since that chart is gone - same
config otherwise, sinks retargeted at `https://opensearch:9200` (TLS + basic auth, see above) with the
VictoriaLogs-proprietary `VL-*`/`AccountID`/`ProjectID` bulk headers dropped and `bulk.index` added for
index naming instead.

## Temporal integration

Not wired up - Temporal's visibility store (`apps/temporal/values.yaml`) uses Postgres SQL today, not
Elasticsearch/OpenSearch, and nothing here changes that. Compatibility exists if ever wanted later:
Temporal officially supports OpenSearch 2+ as of Server v1.32.0 (this cluster's version) via the same
`datastores.visibility.elasticsearch` config block used for Elasticsearch - see the commented-out
example in the `temporal` chart's own `values.yaml`. Would trade Postgres-only simplicity for Advanced
Visibility (custom search attributes on workflow queries), at the cost of Temporal depending on this
OpenSearch cluster's uptime and credentials too. A separate decision, not part of this change.

## Resource footprint

~2.75GB total (client 768Mi + data 1536Mi + dashboards 512Mi container limits) plus the operator itself
(256Mi), noticeably more than VictoriaLogs' old 512Mi (server) + 128Mi (vector). Confirmed against live
headroom at the time this was added: rpi-4b nodes ~2.0-2.7GB free each, rpi-5 nodes ~4.0-4.6GB free each -
fits without pinning anything to a specific node (every pool is left unpinned, scheduler's choice). Worth
knowing: the data pool could land on an rpi-4b, and this repo's own `inventory.dist` comments flag those
nodes' disks as slow/inconsistent for disk-heavy workloads generally (that finding was about etcd and
Longhorn specifically, not measured for OpenSearch/Lucene) - add a nodeSelector back if that turns out to
matter in practice. A second Pi 5 (NVMe, 8GB) is expected soon and would be a better fit for Lucene
segment-merge I/O than any existing node's disk either way.

## One-time cleanup after this change syncs

Deleting `apps/victoria-logs/application.yaml` prunes the `victoria-logs` child Application via the
root app-of-apps, but Argo CD does **not** cascade-delete that Application's own managed resources
without a finalizer (none was set) - its StatefulSet/PVC will be orphaned, not deleted. After this
syncs:
```bash
kubectl delete application victoria-logs -n argocd --cascade=foreground
kubectl -n monitoring get pvc   # find the orphaned VictoriaLogs PVC
kubectl -n monitoring delete pvc <name>
```
