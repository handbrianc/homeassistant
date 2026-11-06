# Home Assistant on k3s (Raspberry Pi 4)

A Helm chart and portable installer scripts to **install and update**
[Home Assistant](https://www.home-assistant.io) on a [k3s](https://k3s.io)
cluster running on Raspberry Pi 4 nodes — with configuration and secrets
flowing through **environment variables** ([12-factor](docs/12-factor.md)).

```text
charts/homeassistant/   Helm chart (single-replica StatefulSet, PVC, env-driven config)
scripts/                bootstrap-cluster.sh / install.sh / update.sh / install-prereqs.sh
docs/                   12-factor mapping, RPi4/k3s node preparation
openspec/               OpenSpec specs & changes (spec-driven development)
.env.example            installer configuration example (copy to .env)
secrets.env.example     Home Assistant secrets example (copy to secrets.env)
```

## Prerequisites

| Tool | Linux | macOS (Homebrew) |
|---|---|---|
| bash 3.2+ (Homebrew bash recommended on macOS) | system | `brew install bash` |
| Helm v3 or v4 | one-liner below | `brew install helm` |
| kubectl (within 1 minor of your cluster) | one-liner below | `brew install kubectl` |
| a k3s cluster | see [docs/rpi4-k3s.md](docs/rpi4-k3s.md) | — |

`kubeconfig` access to the cluster must be configured before installing
(k3s writes it to `/etc/rancher/k3s/k3s.yaml` on the server node).

Or let the repository do it:

```bash
./scripts/install-prereqs.sh          # installs everything below
./scripts/install-prereqs.sh --check  # verify only, installs nothing
```

It is idempotent, works on Linux and macOS, favors **Homebrew** on macOS
(installing Homebrew itself when absent), and on Linux installs official
upstream binaries (helm from get.helm.sh, kubectl from dl.k8s.io,
sha256-verified). Manual install on Linux (Ubuntu/Debian shown):

```bash
# Helm (official installer script; installs to /usr/local/bin via sudo)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

# kubectl — latest stable, self-resolving version (no repo needed)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl

# or, package-managed kubectl (auto-updates; bump v1.37 to your minor)
#   https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/

helm version && kubectl version --client
```

## Quickstart

```bash
# 0. One-time: bootstrap cluster access + configuration
#    Sets up passwordless SSH to the control plane, fetches the k3s
#    kubeconfig (rewriting 127.0.0.1 to the control-plane address),
#    reviews the cluster (nodes, storage, LoadBalancer, ingress, existing
#    release/PVC) and writes .env + scaffolds secrets.env from it.
./scripts/bootstrap-cluster.sh --host pi@192.168.1.10

# 1. Fill in the scaffolded secrets.env with real credentials
$EDITOR secrets.env

# 2. Preview everything (no cluster access, no helm/kubectl needed)
./scripts/install.sh --dry-run

# 3. Install
./scripts/install.sh

# 4. Later: update (e.g. after bumping IMAGE_TAG in .env)
./scripts/update.sh
```

`bootstrap-cluster.sh` is idempotent: re-runs refresh the review, never
duplicate SSH keys, and back up an existing `.env` first. Without `--host`
it runs review-only against an already-working `kubectl`; `--install` chains
straight into `install.sh`. Prefer hand-tuning? Skip it and configure
manually:

```bash
cp .env.example .env && $EDITOR .env
cp secrets.env.example secrets.env && $EDITOR secrets.env
```

The bootstrap report shows every cluster-derived value and the KUBECONFIG
export line for ad-hoc `helm`/`kubectl` use.

## How configuration works (12-factor)

* **Installer/chart settings** live in `.env` (git-ignored) as plain
  `KEY=VALUE` — namespace, release name, image tag, storage class/size, service
  type/port, ingress, timezone. The scripts translate these into a rendered
  Helm values file. Precedence: built-in defaults < `.env` < command-line flags.
* **Secrets** live in `secrets.env` (git-ignored). `install.sh` applies them as
  a Kubernetes Secret named `<release>-secrets`, and the chart injects the
  whole Secret into the container environment via `envFrom`.
* **Home Assistant reads them with `!env_var`** in `configuration.yaml`
  ([official docs](https://www.home-assistant.io/docs/configuration/yaml)):

  ```yaml
  recorder:
    db_url: !env_var HASS_RECORDER_DB_URL
  mqtt:
    password: !env_var MQTT_PASSWORD
  ```

Nothing sensitive is ever committed, rendered into ConfigMaps, or printed to
the terminal. The ignore files (`.gitignore`, `.dockerignore`, chart
`.helmignore`) keep it that way.

## First boot

The chart seeds a minimal `configuration.yaml` into an empty `/config`
(init-container copy-if-missing). Once installed, edit configuration directly
in Home Assistant (Studio Code Server / File editor) or on the PVC — **the
chart never overwrites an existing configuration**.

## Chart defaults (tuned for Raspberry Pi 4)

| Setting | Default | Why |
|---|---|---|
| Controller | StatefulSet, 1 replica | HA is stateful; RWO-PVC-safe rollouts |
| Image | `ghcr.io/home-assistant/home-assistant:2026.11.0` | official, multi-arch (arm64) |
| Persistence | 5Gi PVC at `/config`, cluster-default storage class | k3s `local-path`; set `STORAGE_CLASS=longhorn` for replication |
| Service | `LoadBalancer`, port 8123 | k3s klipper-lb binds the node IP out of the box |
| Probes | startup ≤5 min on `/` | HA first boot is slow on Pi-class nodes |
| Resources | req 200m/512Mi, limit 1.5Gi (no CPU limit) | CPU limits throttle HA startup on Pi nodes |
| Bootstrap config | minimal `configuration.yaml` on first boot only | works immediately, never clobbers user edits |
| Ingress | disabled | enable via `INGRESS_ENABLED=true` + class/host |
| Discovery/USB | off | opt-in `HOST_NETWORK=true` / `usbDevices` values |

Full key reference: `charts/homeassistant/values.yaml` (every key documented)
and the [design contract](openspec/changes/archive/2026-11-05-initialize-homeassistant-k3s/design.md).

## Accessing Home Assistant

* **LoadBalancer (default)** — the service URL printed by `install.sh`; on
  k3s, klipper-lb binds port 8123 on every node IP.
* **NodePort** — set `SERVICE_TYPE=NodePort` and optionally `NODE_PORT=30123`.
* **Ingress** — set `INGRESS_ENABLED=true`, `INGRESS_CLASS=traefik`,
  `INGRESS_HOST=homeassistant.example.com` (Traefik ships with k3s).
* **Port-forward fallback** — `kubectl port-forward svc/homeassistant 8123:8123`.

## Advanced: discovery and USB radios

* `HOST_NETWORK=true` binds the pod to a node's host network so mDNS/SSDP/UPnP
  discovery works on your LAN (`dnsPolicy` is set automatically). Multicast on
  Kubernetes is best-effort; MQTT or ESPHome-style discovery is more reliable.
* Zigbee/Z-Wave sticks: add a `usbDevices` value entry
  (`{name: zigbee, hostPath: /dev/serial/by-id/<...>}`) to pass the device
  through. Prefer `/dev/serial/by-id/...` over `/dev/ttyUSB0` (stable across
  reboots). See [docs/rpi4-k3s.md](docs/rpi4-k3s.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Service `EXTERNAL-IP` stuck `<pending>` | no LB implementation — use `SERVICE_TYPE=NodePort`, or install MetalLB |
| Pod `CrashLoopBackOff` early on | check `kubectl logs`; first boot on Pi4 can take minutes — the startup probe budgets 5 min |
| `!env_var` resolves empty | the key is missing from `secrets.env`/the Secret — re-run `./scripts/install.sh` after editing, or set a default: `!env_var KEY default` |
| Update broke HA | `helm history homeassistant` then `helm rollback homeassistant <rev>` |
| Config resets on every pod start | you replaced `/config/configuration.yaml` with a mount — mount extra config via `extraVolumes`/`extraVolumeMounts` values instead |

## Development workflow (OpenSpec)

This repo uses [OpenSpec](https://openspec.dev) (spec-driven development) and
[CodeGraph](https://codegraph.dev) for code intelligence:

```bash
openspec list --specs                                     # capability specs (source of truth)
openspec validate --all                                   # structural checks
codegraph explore "statefulset templates"                 # indexed code queries (after .codegraph/ build)
```

Changes are proposed as OpenSpec changes (`openspec new change <name>`),
implemented against the specs, and archived into `openspec/changes/archive/`
when complete (specs merge into `openspec/specs/`).

## Uninstalling

```bash
helm uninstall homeassistant -n homeassistant
kubectl delete pvc -l app.kubernetes.io/instance=homeassistant -n homeassistant  # deletes data!
```
