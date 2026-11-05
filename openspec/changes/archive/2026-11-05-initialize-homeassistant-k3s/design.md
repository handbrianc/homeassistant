# Design: initialize-homeassistant-k3s

## Technical Approach

Two independent deliverables built in parallel lanes against this contract:

1. **Helm chart** (`charts/homeassistant/`) — declarative workload, sane RPi4/k3s defaults.
2. **Bash installers** (`scripts/`) — env-file driven install/update glue around `helm upgrade --install`.

The installer scripts and the chart share one contract: the **env → values
mapping** below and the **secret naming** convention. Both lanes must implement
exactly that contract so the scripts stay a thin wrapper over the chart.

Home Assistant specifics baked into the design (from official docs):
- Official image `ghcr.io/home-assistant/home-assistant:<version>` is
  multi-arch (linux/arm64 included); latest stable at init time: **2026.11.0**.
- The container reads configuration values from environment variables only
  where `configuration.yaml` uses `!env_var VAR [default]`
  (https://www.home-assistant.io/docs/configuration/yaml — "Environment
  variables"). This is the 12-factor secret path.
- The frontend answers HTTP 200 on `/` without authentication; `/api/`
  requires a token (401) — probes therefore use `/`.
- First boot creates `/config`; a minimal bootstrap `configuration.yaml` can be
  seeded by an init container copy-if-missing.
- Home Assistant is single-replica: the controller is a StatefulSet (stable
  identity, avoids RWO-PVC multi-attach deadlocks during rollouts on
  multi-node clusters).

## Chart contract (charts/homeassistant/)

### Files

```
charts/homeassistant/
├── Chart.yaml              # apiVersion v2, name homeassistant, version 0.1.0, appVersion 2026.11.0
├── values.yaml             # defaults below
├── .helmignore             # already present at repo scaffold
├── templates/
│   ├── _helpers.tpl        # fullname/chart/labels/selectorLabels/sa-name
│   ├── serviceaccount.yaml # conditional on serviceAccount.create
│   ├── configmap.yaml      # bootstrapConfig (optional)
│   ├── secret.yaml         # only when secretEnv non-empty (chart-managed secret)
│   ├── pvc.yaml            # conditional (enabled && !existingClaim)
│   ├── service.yaml        # main Service + headless Service (StatefulSet serviceName)
│   ├── statefulset.yaml    # the workload
│   ├── ingress.yaml        # conditional
│   ├── NOTES.txt
│   └── tests/test-connection.yaml  # helm test hook: busybox wget to the Service
└── tests/
    └── test-connection.yaml (as above; lives in templates/tests/)
```

### values.yaml keys and defaults (exact names — shared contract)

```yaml
nameOverride: ""
fullnameOverride: ""
image:
  repository: ghcr.io/home-assistant/home-assistant
  tag: "2026.11.0"            # pinned; appVersion must match
  pullPolicy: IfNotPresent
imagePullSecrets: []
replicaCount: 1               # must stay 1; HA is single-replica
revisionHistoryLimit: 3
terminationGracePeriodSeconds: 60
timezone: "UTC"               # -> TZ env
serviceAccount:
  create: true
  annotations: {}
  name: ""
service:
  type: LoadBalancer          # k3s klipper-lb binds node IP out of the box
  port: 8123
  nodePort: null              # only used when type == NodePort
  loadBalancerIP: null        # rendered when set (MetalLB etc.)
  externalTrafficPolicy: null # rendered when set
hostNetwork: false            # true + dnsPolicy for mDNS/UPnP discovery
dnsPolicy: null               # when hostNetwork: ClusterFirstWithHostNet
usbDevices: []                # [{name: zigbee, hostPath: /dev/ttyUSB0, type: CharDevice}]
persistence:
  enabled: true
  existingClaim: null
  storageClass: null          # k3s default local-path; longhorn for replication
  accessMode: ReadWriteOnce
  size: 5Gi
envFromSecret: "homeassistant-secrets"  # external Secret (scripts create it); "" disables
secretEnv: {}                 # chart-managed Secret fallback (pure-helm users)
extraEnv: []                  # [{name: X, value: Y}] or valueFrom entries
extraEnvFrom: []              # extra envFrom sources (configMapRef/secretRef)
probes:
  path: "/"                   # unauthenticated HTTP 200
  startup: {periodSeconds: 10, failureThreshold: 30}   # ~5 min budget
  readiness: {periodSeconds: 10, failureThreshold: 3, timeoutSeconds: 2}
  liveness: {periodSeconds: 30, failureThreshold: 3, timeoutSeconds: 5}
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits: {memory: 1.5Gi}     # deliberately NO cpu limit (Pi throttling)
podAnnotations: {}
podLabels: {}
nodeSelector: {}
tolerations: []
affinity: {}
podSecurityContext: {}        # official image runs as root to manage /config
securityContext: {}           # e.g. PUID/PGID style images can set runAsUser
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts:
    - host: homeassistant.local
      paths: [{path: /, pathType: Prefix}]
  tls: []
extraVolumes: []
extraVolumeMounts: []
bootstrapConfig:
  enabled: true
  existingConfigMap: ""       # alternative source for bootstrap config
  configuration: |
    # Bootstrap configuration written on first boot only (empty /config).
    # Secrets are provided as environment variables (12-factor) and read with
    # !env_var. Extend this file in /config; it is never overwritten.
    default_config:
    logger:
      default: warning
    # Example:
    # recorder:
    #   db_url: !env_var HASS_RECORDER_DB_URL
```

### Template rules

- **StatefulSet**: `serviceName: <fullname>-headless`; container port name
  `http`, 8123, protocol TCP; env order: `TZ` (from `timezone`), `envFrom`
  (envFromSecret when set, chart secret when secretEnv non-empty, extraEnvFrom),
  `extraEnv`; volume mounts: `/config` (pvc/emptyDir), usbDevices hostPath
  volumes (mount path = hostPath), extraVolumes; probes per values (httpGet,
  port `http`); hostNetwork/dnsPolicy only when hostNetwork true; nodeSelector,
  tolerations, affinity, podSecurityContext/securityContext, resources,
  podAnnotations/podLabels, serviceAccountName; `updateStrategy: RollingUpdate`.
- **init container** (only when bootstrapConfig.enabled or existingConfigMap):
  `busybox:1.37` (multi-arch), mounts `/config` (same volume) read-write and
  the bootstrap ConfigMap read-only at `/bootstrap-config`; command:
  copy `configuration.yaml` only when `/config/configuration.yaml` is missing.
- **pvc.yaml**: rendered when `persistence.enabled && !existingClaim`; storageClass
  rendered only when set; the StatefulSet consumes it by name (volume, not
  volumeClaimTemplates — resizes/storage-class changes stay manageable).
- **service.yaml**: main Service `type/port/nodePort/loadBalancerIP/
  externalTrafficPolicy` as configured (omit nodePort unless NodePort; omit
  loadBalancerIP/externalTrafficPolicy unless set); headless Service
  `<fullname>-headless` with `clusterIP: None` (selector-based).
- **secret.yaml**: rendered ONLY when `secretEnv` non-empty; `stringData` map.
- **NOTES.txt**: frontend URL (LB IP/NodePort/host hints), update command
  (`scripts/update.sh`), bootstrap-config note.
- **tests/test-connection.yaml**: `helm test` hook Pod, `busybox:1.37`,
  `wget -qO- http://<fullname>:<port>/ | head -c 200` style check, restart
  Never, backoffLimit small.

## Scripts contract (scripts/)

### Files

```
scripts/
├── install.sh              # entry: first install / converge
├── update.sh               # entry: update existing release
└── lib/common.sh           # shared: logging, env loading, defaults, values render, secret apply
```

### Shared behavior (lib/common.sh)

- Sourced after entry script sets `set -Eeuo pipefail`.
- `log_info/log_ok/log_warn/log_error`: printf-based, ANSI colors, respect
  `NO_COLOR`, stderr for warn/error.
- `die "msg"`: error + exit 1.
- `require_cmds cmd...`: friendly per-tool failure with install hint
  (`apt install helm` / `brew install helm kubectl bash`); skipped entirely in
  dry-run mode.
- `load_env_file <path>`: source `KEY=VALUE` file with `set -a` (defaults in
  `.env.example` mirror this). Missing file → warn, continue with defaults.
- `apply_defaults`: `: "${VAR:=default}"` for every variable in `.env.example`.
- `assert_yaml_safe VAR value`: reject values containing `"`, `'`, `\`,
  backtick, newline, `$` — abort naming the variable.
- `render_values_file <outfile>`: write YAML from env per the mapping table
  below (only non-empty vars emitted; `true/false` parsed case-insensitively).
- `create_or_update_secret`: when secrets file exists and readable →
  `kubectl create secret generic "$SECRET_NAME" --from-env-file="$SECRETS_FILE"`
  `--dry-run=client -o yaml | kubectl apply -f - -n "$NAMESPACE"` (no secret
  values echoed). Missing file → warn, export `ENV_FROM_SECRET=""`.
- `cleanup`: trap-based removal of the generated temp values file.
- Portability: bash 3.2+ only (no associative arrays, no `mapfile`, no
  `${var,,}`, no negative-length substring ops beyond `${var: -1}` avoided),
  `#!/usr/bin/env bash` in entry scripts, no GNU-only utilities
  (`readlink -f`, `sed -i`, `date -d`, `stat -c`), `mktemp` + `trap`, paths via
  `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` chain, quote everything.

### Entry script behavior (install.sh / update.sh)

1. `set -Eeuo pipefail`; resolve `REPO_ROOT`; parse flags: `-h/--help`,
   `--dry-run` (also honors `DRY_RUN=1`), `--namespace X`, `--release NAME`,
   `--values FILE` (extra values, applied last).
2. `load_env_file "$REPO_ROOT/.env"`; `apply_defaults`.
3. Dry-run? skip `require_cmds` and cluster check; else require
   `helm` (v3) + `kubectl` and `kubectl get nodes` reachability check with a
   short timeout.
4. `assert_yaml_safe` every interpolated value.
5. `create_or_update_secret` (unless `SECRETS_FILE` empty; dry-run prints the
   kubectl pipeline instead of running it).
6. `render_values_file` → temp file (trap-cleaned).
7. Helm:
   `helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" --namespace "$NAMESPACE"`
   `--create-namespace --atomic --timeout "$HELM_TIMEOUT" --set envFromSecret="$ENV_FROM_SECRET"`
   `-f <generated> [-f VALUES_EXTRA] [--set image.tag="$IMAGE_TAG"]`
   (image.tag re-asserted so an IMAGE_TAG change needs no values edit; dry-run
   prints the command and the generated values, then exits 0.)
8. Post (skipped in dry-run): `kubectl rollout status statefulset/<fullname>`
   with `--timeout="$HELM_TIMEOUT"`; print access URL(s) from
   `kubectl get svc`; for `update.sh` also `helm history` + rollback hint.
9. `install.sh` prints post-install pointers (open URL, `helm test` command).

### Env → values mapping (shared contract)

| Env var | Values path | Emitted when |
|---|---|---|
| IMAGE_TAG | image.tag (+ `--set image.tag`) | always |
| TIMEZONE | timezone | always |
| STORAGE_CLASS | persistence.storageClass | non-empty |
| STORAGE_SIZE | persistence.size | non-empty |
| SERVICE_TYPE | service.type | non-empty |
| SERVICE_PORT | service.port | non-empty |
| LOADBALANCER_IP | service.loadBalancerIP | non-empty |
| NODE_PORT | service.nodePort | non-empty |
| INGRESS_ENABLED | ingress.enabled | non-empty (`true`/`false`) |
| INGRESS_CLASS | ingress.className | non-empty |
| INGRESS_HOST | ingress.hosts[0].host | non-empty |
| HOST_NETWORK | hostNetwork (+dnsPolicy ClusterFirstWithHostNet when true) | non-empty |
| NODE_ARCH | nodeSelector.kubernetes.io/arch | non-empty |
| NAMESPACE / RELEASE_NAME / CHART_DIR / HELM_TIMEOUT / VALUES_EXTRA / SECRETS_FILE | helm invocation args | always |

Secret name convention: `<RELEASE_NAME>-secrets`; `ENV_FROM_SECRET` defaults to
that name and is forced empty when the secrets file is absent.

### Verification (lane-owned before hand-off)

- `bash -n` and `shellcheck` (clean or explicitly justified) on all scripts.
- `DRY_RUN=1 bash scripts/install.sh` and `DRY_RUN=1 bash scripts/update.sh`
  exit 0, printing commands and generated values, with no helm/kubectl on PATH.
- Stub end-to-end: fake `helm`/`kubectl` shell stubs on PATH that log args and
  exit 0; assert install.sh reaches the rollout/URL stage and passes
  `--create-namespace --atomic --namespace homeassistant`.
- A secrets-file-missing run renders with `envFromSecret: ""`.

## Risks / trade-offs

- **StatefulSet vs Deployment**: StatefulSet chosen for RWO-PVC safety on
  multi-node rollouts; cost is a headless service in the namespace.
- **No CPU limit**: protects HA startup latency on Pi nodes; documented in
  values comments.
- **Bootstrap config copy-if-missing**: never overwrites user config; the
  ConfigMap is informational after first boot (documented in NOTES).
- **envFrom secrets**: all keys in `secrets.env` become container env — the
  file must only contain keys Home Assistant should see (documented in
  secrets.env.example).
- **hostNetwork discovery**: multicast discovery on k8s is best-effort;
  default stays off, documented as opt-in.
