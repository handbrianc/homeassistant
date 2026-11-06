# Proposal: bootstrap-cluster-script

## Why

Before `install.sh`/`update.sh` can run, a user must manually: copy the k3s
kubeconfig off the control-plane host, make it point at a reachable API
server, set up SSH access, and then hand-pick chart values (storage class,
service type, node architecture, image tag) that match the cluster. That is
error-prone guesswork. One script should do the access bootstrap and produce a
cluster-aware `.env`, so that afterwards `helm`/`kubectl` work and the
existing installers run as-is.

## What Changes

- Add `scripts/bootstrap-cluster.sh` with three stages:
  1. **Access**: set up passwordless SSH from this (client) host to the
     control-plane host (`--host [user@]ip`), pull `/etc/rancher/k3s/k3s.yaml`
     (scp, with `sudo cat` fallback), rewrite the `server:` URL from
     `127.0.0.1`/`localhost` to the control-plane address, install it at
     `~/.kube/homeassistant-k3s.yaml` (mode 600) and validate with
     `kubectl get nodes`.
  2. **Review**: query the cluster (kubectl, and helm when a release already
     exists) to derive sane chart values: node architectures, default storage
     class, LoadBalancer capability (klipper-lb / assigned ingress IPs),
     ingress classes, live release image tag, existing PVC size/class, and the
     key *names* (never values) of the release secret.
  3. **Config**: back up any existing `.env`, write a fully populated
     `.env` (same variable contract as `.env.example`), scaffold `secrets.env`
     from the example (mode 600) when missing, and print next steps.
- `--install` optionally chains straight into `scripts/install.sh` afterwards.
- Without `--host`, the script runs review-only against an already-working
  `kubectl` (skips SSH/fetch stages).
- README quickstart gains the bootstrap step.

## Capabilities

### installer-cli

Existing capability, extended: adds cluster *access bootstrap* and
cluster-aware *configuration generation* next to the existing install/update
flows.

## Impact

- Affected specs: `installer-cli` (one ADDED requirement).
- Affected code: new `scripts/bootstrap-cluster.sh`; README quickstart.
  No changes to the chart or to install/update behavior: the generated `.env`
  uses the existing variable contract, so `install.sh`/`update.sh` work
  unmodified.
