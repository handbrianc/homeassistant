# Tasks: initialize-homeassistant-k3s

## 1. Project scaffolding

- [x] 1.1 Initialize git (`main`), ignore files (`.gitignore`, `.dockerignore`, chart `.helmignore`)
- [x] 1.2 Initialize OpenSpec (`openspec init --tools opencode`) and codegraph
- [x] 1.3 Environment examples (`.env.example`, `secrets.env.example`) with 12-factor secret flow

## 2. Helm chart (charts/homeassistant/)

- [x] 2.1 `Chart.yaml`, `values.yaml` with contract defaults (design.md)
- [x] 2.2 `templates/_helpers.tpl`, `serviceaccount.yaml`
- [x] 2.3 `configmap.yaml` (bootstrap) + `secret.yaml` (secretEnv fallback)
- [x] 2.4 `pvc.yaml`, `service.yaml` (main + headless)
- [x] 2.5 `statefulset.yaml` (init container, probes, env wiring, usbDevices, hostNetwork)
- [x] 2.6 `ingress.yaml`, `NOTES.txt`, `tests/test-connection.yaml`
- [x] 2.7 Validate: `helm lint`, `helm template` defaults + edge-case values (NodePort, ingress, hostNetwork, usbDevices, persistence off, secretEnv)

## 3. Installer scripts (scripts/)

- [x] 3.1 `lib/common.sh` (logging, env loading, defaults, yaml-safety, values render, secret apply, traps)
- [x] 3.2 `install.sh` (flags, prereqs, secret, helm install, rollout wait, URLs)
- [x] 3.3 `update.sh` (idempotent upgrade, history + rollback hint)
- [x] 3.4 Validate: `bash -n`, `shellcheck`, `DRY_RUN` runs, stub helm/kubectl end-to-end, missing-secrets-file path

## 4. Documentation

- [x] 4.1 `README.md` (quickstart, secrets flow, chart defaults, troubleshooting)
- [x] 4.2 `docs/12-factor.md` (factor-by-factor mapping)
- [x] 4.3 `docs/rpi4-k3s.md` (node prep: 64-bit OS, cgroups, SSD, k3s install, storage options)

## 5. Final verification

- [x] 5.1 Reconcile lanes; full chart + script verification suite from repo root
- [x] 5.2 `openspec validate --all` passes
- [x] 5.3 Initial git commit (secrets scan before staging)
