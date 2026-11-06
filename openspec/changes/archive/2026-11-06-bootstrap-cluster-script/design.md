# Design: bootstrap-cluster-script

## Technical Approach

`scripts/bootstrap-cluster.sh` sources `scripts/lib/common.sh` (logging,
`die`, `assert_yaml_safe`, trap-based temp cleanup) and runs three stages.

### Stage 1 — Access (skipped without `--host`)

1. Resolve the SSH key (`--ssh-key`, default `$HOME/.ssh/id_ed25519`):
   generate (`ssh-keygen -t ed25519 -N ''`) when missing; the public key is
   re-derived with `ssh-keygen -y` so a missing `.pub` file is handled.
2. Install the key on the control plane idempotently — the public key core
   (first two fields, plus no comment from the remote side) is appended to
   `~/.ssh/authorized_keys` guarded by `grep -qxF`, so re-runs add no
   duplicates. First attempt uses `-o BatchMode=yes`; on failure the script
   retries once interactively (the one-time password/2FA prompt) and then
   verifies passwordless access with `-o BatchMode=yes
   -o PasswordAuthentication=no`. `StrictHostKeyChecking=accept-new`
   records host keys without prompting.
3. Fetch `--remote-config` (default `/etc/rancher/k3s/k3s.yaml`) via
   `scp`; when the file is not directly readable (root-owned, mode 600) fall
   back to `ssh host "sudo cat <path>" > file`. Both failing is fatal with the
   `--write-kubeconfig-mode` hint from `docs/rpi4-k3s.md`.
4. Rewrite the `server:` URL with awk (never `sed -i`): every
   `^[[:space:]]*server:` line is replaced with
   `https://<control-plane-host>:<port>`, port taken from the fetched file
   (default 6443), indentation preserved. Host = `[user@]host` without the
   user part.
5. Validate `KUBECONFIG=<dest> kubectl get nodes --request-timeout=15s`;
   failure is fatal with the `--tls-san` hint (k3s must have been installed
   with the control-plane IP in the API serving cert SANs). The kubeconfig is
   left in place for inspection.

### Stage 2 — Review (kubectl/go-template, never parses secrets' values)

All queries use `go-template`/`jsonpath` (no `jq` dependency):

| Question | Query | Sets |
|---|---|---|
| node arches | `get nodes -o go-template '{{range .items}}{{.status.nodeInfo.architecture}}…'` → unique | `NODE_ARCH` (empty + warn when mixed) |
| default storage class | `get sc -o go-template` filtered on the is-default-class annotation | `STORAGE_CLASS` (empty when none/multiple, with a note) |
| LB capability | `get svc -A` LoadBalancer services with assigned `.status.loadBalancer.ingress` IPs/hostnames, else `svclb*` DaemonSet in kube-system | `SERVICE_TYPE=LoadBalancer`; else `NodePort` + `NODE_PORT=30812` + warn |
| ingress class | `get ingressclasses` | `INGRESS_CLASS` (Traefik preferred; `INGRESS_ENABLED` stays false — opt-in) |
| existing release | `helm list --short` exact-name match (helm optional — skipped with a warning when absent) | `IMAGE_TAG` from the live StatefulSet's `containers[0].image` tag (chart default otherwise) |
| existing PVC | `get pvc -l app.kubernetes.io/instance=<release>` | `STORAGE_SIZE`/`STORAGE_CLASS` from the claim (update never shrinks/moves storage) |
| secret keys | `get secret <release>-secrets -o go-template` over `.data` | key *names* only, for the report |
| timezone | over SSH only: `timedatectl show -p Timezone --value \|\| cat /etc/timezone` | `TIMEZONE` (UTC fallback, sanitized) |

Namespace existence is reported; helm is optional (absent helm ⇒ release
detection skipped with a warning, chart-default image tag used).

### Stage 3 — Configuration

- Existing `.env` → backup `.env.backup-YYYYmmddHHMMSS` (portable `date`).
- Every value passes `assert_yaml_safe` before writing; values are written
  `KEY="VALUE"` (double quotes make space-containing paths safe; the quote
  ban inside values is already enforced). `KUBECONFIG` is written as an
  absolute path (`~` never appears — it would not expand inside quotes).
- `secrets.env` scaffolded from `secrets.env.example` (mode 600) when
  missing; existing file → key names only.
- Final report: derived values, secret key names, `export KUBECONFIG=…`
  line for ad-hoc `helm`/`kubectl`, next steps (`install.sh --dry-run`,
  then real run). `--install` chains into `scripts/install.sh` directly.

## Flags

`--host [user@]ip`, `--ssh-port N` (22), `--ssh-key PATH`
(`$HOME/.ssh/id_ed25519`), `--remote-config PATH`
(`/etc/rancher/k3s/k3s.yaml`), `--kubeconfig-dest PATH`
(`$HOME/.kube/homeassistant-k3s.yaml` — deliberately not `~/.kube/config`,
which must never be clobbered), `--kubeconfig PATH` (use this existing
config instead of fetching, review-only), `--namespace NS`,
`--release NAME`, `--install`.

## Portability & security

Same rules as the other scripts: bash 3.2+, no GNU-only utilities, `mktemp`
+ trap cleanup, quoted expansions, `set -Eeuo pipefail`. `%q`-quoted values
in the remote authorized_keys command prevent shell injection. Secret
*values* are never printed anywhere; only key names are reported.

## Non-goals

- Installing k3s itself (node provisioning: `docs/rpi4-k3s.md`).
- Creating the Home Assistant release (that is `install.sh`'s job; the
  hand-off is a finished `.env`).
- Multi-cluster or non-k3s fetch paths (any reachable kubeconfig works via
  `--kubeconfig`).
