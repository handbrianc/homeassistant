# 12-Factor compliance

[The Twelve-Factor App](https://12factor.net) applied to Home Assistant on
k3s. Home Assistant is a stateful, single-process application, so some factors
are satisfied "as far as practical" — deviations are listed explicitly rather
than hidden.

| # | Factor | How this project complies |
|---|---|---|
| 1 | **Codebase** | One repo = one deployable unit: Helm chart + installer scripts + specs. Any k3s cluster is deployable from a clean clone. |
| 2 | **Dependencies** | All dependencies are explicitly declared and pinned: `IMAGE_TAG` pins the Home Assistant version (default `2026.11.0`), `Chart.yaml` declares the chart's own version/`appVersion`, and installer scripts assert required tooling (`helm`, `kubectl`, bash 3.2+) before running. |
| 3 | **Config** | Configuration is stored in the environment, never in code: installer settings in `.env` → rendered Helm values; runtime config as container env (`TZ`, `extraEnv`); secrets as a Kubernetes Secret injected via `envFrom`. Home Assistant reads env vars in `configuration.yaml` with [`!env_var VAR [default]`](https://www.home-assistant.io/docs/configuration/yaml). `.env.example` / `secrets.env.example` document every variable; real files are git-ignored. |
| 4 | **Backing services** | Backing services are attached resources addressable by URL/credentials: the recorder database defaults to SQLite on the PVC and can be swapped to PostgreSQL/MariaDB purely via the `HASS_RECORDER_DB_URL` env var (example in `secrets.env.example`); MQTT/InfluxDB attach the same way. No rebuild needed to change backing services. |
| 5 | **Build, release, run** | Build (chart packaging) and run (helm install) are separated: the chart is versioned source, each `helm upgrade` is an immutable release revision with a generated values file, and `IMAGE_TAG` selects the exact runtime version. `update.sh` starts a new release; `helm rollback` returns to a previous one. |
| 6 | **Processes** | The app runs as a single stateless-ish process — HA is a single monolithic process by design; the chart enforces `replicas: 1` (StatefulSet) and *documents* rather than hides it. Horizontally scaling the frontend is achieved with companion services (reverse proxy/ingress), not by scaling HA itself. |
| 7 | **Data disposal** | State is explicit: all HA state lives in `/config` on a PVC. The recorder/long-term data can be moved to an external database (factor 4), which makes the pod itself disposable — any pod can be destroyed and replaced; only the PVC persists. |
| 8 | **Elastic scale** | Vertical scaling is a values change (`resources`). Horizontal scaling is intentionally capped at one replica (factor 6); HA Core does not support multi-writer state. Scale-out is delegated to attached services (database, MQTT broker, ingress). |
| 9 | **Disposability** | The pod is disposable: generous startup probe budget (≤5 min) tolerates slow Pi boots without false restarts; `terminationGracePeriodSeconds: 60` lets HA flush the recorder on `SIGTERM`; `helm --atomic` rolls back failed upgrades automatically. |
| 10 | **Dev/prod parity** | The same chart deploys everywhere; environments differ only in environment files (`.env`) and optional extra values (`VALUES_EXTRA`). A laptop kind/k3d cluster and a RPi4 k3s cluster run the identical chart. |
| 11 | **Logs** | Home Assistant logs to stdout/stderr; the container adds no log files. Treat logs as event streams: `kubectl logs -f deploy/...` / `stern`. Log destination (loki, fluent-bit) is a cluster concern, not a chart concern. |
| 12 | **Admin processes** | One-off admin tasks run as one-off processes: `kubectl exec` into the pod, `helm test` (chart ships a connection test), and the scripts themselves are idempotent admin entry points (`install.sh`, `update.sh`). |

## Explicit deviations (and why)

| Deviation | Rationale |
|---|---|
| State lives on a PVC, not in a backing service (factor 4/7) | Home Assistant's registry, auth, UI config and entity history are not designed for external storage; the PVC keeps the *pod* disposable while state stays explicit and backed up-able (longhorn snapshot / k8up). |
| Fixed 1 replica (factor 6/8) | HA Core is not safe to run concurrently; enforced via StatefulSet instead of trusting operators. |
| Bootstrap `configuration.yaml` seeded on first boot (factor 3) | HA cannot run without a config file; the file is seeded once, never overwritten, and secrets within it come from the environment — the closest practical match to "config in env". |
| No CPU limit on the container (factor 9) | CPU limits measurably slow HA startup on Pi-class nodes; memory limit retained to protect the node. |
