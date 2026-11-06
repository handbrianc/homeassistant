# Tasks: bootstrap-cluster-script

## 1. Script

- [x] 1.1 `scripts/bootstrap-cluster.sh`: flag parsing, access stage (key gen/install, scp+sudo-cat fetch, awk server-URL rewrite, validation), review stage (nodes/SC/LB/ingress/release/PVC/secret-keys/timezone), config stage (.env backup+write, secrets scaffold), report + `--install` hand-off

## 2. Verification

- [x] 2.1 `bash -n` + `shellcheck` clean
- [x] 2.2 Stubbed ssh/scp/kubectl/helm end-to-end: LoadBalancer variant (kubeconfig rewrite, `.env` values, secrets scaffold, keys-only report), NodePort fallback variant, review-only variant, `.env` backup, scp-failure sudo-cat fallback
- [x] 2.3 Real smoke: no kubectl on PATH → friendly error pointing at `scripts/install-prereqs.sh`
- [x] 2.4 macOS path: portability audit (no GNU-only constructs; not executable here — stated)

## 3. Close-out

- [x] 3.1 README quickstart includes the bootstrap step; `openspec validate --all` passes
- [x] 3.2 Change archived; committed
