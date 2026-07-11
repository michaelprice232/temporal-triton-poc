# Step 2 — Temporal control plane

Install the Temporal OSS control plane into the cluster with the official Helm
chart, pointed at the Aurora PostgreSQL cluster from step 1 over TLS.

## What gets deployed

The chart (v1.5.0, Temporal server 1.31) deploys the four Temporal services
(frontend, history, matching, worker) plus the Web UI, into the `temporal`
namespace. Persistence and **advanced visibility both use SQL** — no
Elasticsearch — so Aurora is the only datastore.

## Files

- [`values.aurora-postgres.yaml`](./values.aurora-postgres.yaml) — chart values for external Aurora.
- [`install-temporal.sh`](./install-temporal.sh) — creates the DB-password secret and runs `helm upgrade --install`.

## Run it

```bash
# 1. Set the Aurora WRITER endpoint (from step 1) in the values file:
#    connectAddr: "REPLACE_AURORA_WRITER_ENDPOINT:5432"  (both stores)

# 2. Supply the DB password out-of-band (never committed), then install:
export TEMPORAL_DB_PASSWORD='...'
./install-temporal.sh
```

Verify:

```bash
kubectl -n temporal get pods                 # all Running
kubectl -n temporal port-forward svc/temporal-web 8080:8080
open http://localhost:8080                    # UI, "default" namespace present
```

## Key configuration decisions

These are the non-obvious bits, all in `values.aurora-postgres.yaml`:

- **`pluginName: postgres12`** — required for PostgreSQL ≥ 12 (the old `postgres`
  plugin is for pre-12).
- **`createDatabase: false`, `manageSchema: true`** — the two databases are
  pre-created (step 1c), so the schema job skips `create-database` but still runs
  `setup-schema` + `update-schema` to build all the tables. `manageSchema`
  defaults to `true`; `createDatabase` defaults to `true`, hence the explicit
  override.
- **`existingSecret`** — the DB password is pulled from a k8s secret
  (`temporal-db-passwords`, created by the install script) and is **never**
  written into the rendered ConfigMap. The chart rewrites it to
  `{{ env "TEMPORAL_..._STORE_PASSWORD" }}`.
- **`tls.enabled: true`, `enableHostVerification: false`** — encrypt to Aurora
  (satisfies `rds.force_ssl`) without needing to mount the RDS CA bundle.
  Equivalent to `sslmode=require`. This flows to the schema job too, not just the
  server.
- **`shims.dockerize/elasticsearchTool: false`** — correct for the 1.31 images
  the chart ships (the shims exist only for 1.29 compatibility).
- **`numHistoryShards: 512`** — IMMUTABLE after first install; 512 is a safe
  default for a POC and beyond.

Schema setup runs as a Helm **pre-install/pre-upgrade hook**, so `helm upgrade`
re-runs `update-schema` idempotently — that's how Temporal version bumps migrate
the DB.

## Going to production

- Enable client-side cert verification: `enableHostVerification: true` + mount
  the RDS global CA bundle via `tls.caFile`, set `serverName`.
- Manage the DB secret with a real secrets store (External Secrets / SOPS /
  sealed-secrets) rather than a script-created secret.
- Scale `server.replicaCount` and set resource requests/limits per service.
