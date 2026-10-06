# OpenSearch

This cluster's log store: one Vector DaemonSet ships every container's logs plus host journald into
OpenSearch + OpenSearch Dashboards (VictoriaLogs, the previous store, is gone). HA layout: two client pods and
two data pods, each with its own PVC, indices with one replica (see "Redundancy" below).

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

## Retention: 7d

Enforced by `manifests/ism-policy.yaml`'s `min_index_age: 7d` transition to a `delete` state, at
daily-index granularity (`logs-%Y.%m.%d` / `logs-host-%Y.%m.%d` - `values-vector.yaml`'s `bulk.index`).
This is index-boundary granularity, not an exact 7d cutoff - data can live up to ~8d in the worst case.

## Redundancy

- **Pods**: 2 `client` (cluster-manager-eligible + ingest) and 2 `data` (data + cluster-manager-eligible),
  each pool with required anti-affinity (the two pods of a pool never share a node) and a PDB
  (`maxUnavailable: 1`). Four manager-eligible nodes give a 3-voter set: any single node can be lost.
- **Storage**: each pod has its own Longhorn PVC (client 2Gi, data 10Gi). Indices use
  `number_of_replicas: 1` (`manifests/index-template.yaml`), so every shard has a copy on each data node,
  on top of Longhorn's own volume replication. Losing a data pod, its node or its volume loses no logs.
- **Existing indices** created before this was enabled keep `number_of_replicas: 0`: raise them once with
  `PUT logs-*/_settings {"index":{"number_of_replicas":1}}` (and the same for `logs-host-*`).
- **Cost**: about 1.5Gi memory per OpenSearch pod (6Gi total across the Pi 5s, was 3Gi).

## Log shipping

Reuses this cluster's existing Vector DaemonSet rather than introducing a new shipper (Fluent Bit is the
more common default for k8s→OpenSearch specifically, but Vector's `elasticsearch` sink is
[documented as fully OpenSearch-compatible](https://vector.dev/docs/reference/configuration/sinks/elasticsearch/),
and this cluster already runs it). Sourced from Vector's own chart (`https://helm.vector.dev`); two sinks (container
and host logs) at `https://opensearch:9200` (TLS + basic auth, see above), `bulk.index` for index naming. Memory
and I/O are bounded on the Pi 4Bs (see the comments in `values-vector.yaml`).

## Temporal integration

Not wired up - Temporal's visibility store (`apps/temporal/values.yaml`) uses Postgres SQL today, not
Elasticsearch/OpenSearch, and nothing here changes that. Compatibility exists if ever wanted later:
Temporal officially supports OpenSearch 2+ as of Server v1.32.0 (this cluster's version) via the same
`datastores.visibility.elasticsearch` config block used for Elasticsearch - see the commented-out
example in the `temporal` chart's own `values.yaml`. Would trade Postgres-only simplicity for Advanced
Visibility (custom search attributes on workflow queries), at the cost of Temporal depending on this
OpenSearch cluster's uptime and credentials too. A separate decision, not part of this change.

## Resource footprint

About 8.6GB of container memory limits in total: client 2 x 1536Mi + data 2 x 1536Mi + dashboards 512Mi, plus
the operator (256Mi). Every OpenSearch pod is pinned to a Pi 5 (`pi5=true`): the Amazon Linux image can't
run on a Pi 4B CPU. Spread across the four Pi 5s that is roughly 2GB each; watch `kubectl top nodes` -
the Pi 5s were already at 56-71% memory before this layout.

## One-time cleanup after VictoriaLogs was removed

Deleting `apps/victoria-logs/application.yaml` prunes the `victoria-logs` child Application via the
root app-of-apps, but Argo CD does **not** cascade-delete that Application's own managed resources
without a finalizer (none was set) - its StatefulSet/PVC are orphaned. After the removal syncs:
```bash
kubectl delete application victoria-logs -n argocd --cascade=foreground
kubectl -n monitoring get pvc | grep vls      # the orphaned VictoriaLogs volume
kubectl -n monitoring delete pvc <name>
kubectl -n monitoring delete cm victorialogs-grafana-ds   # if still present
```
