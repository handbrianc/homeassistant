# installer-cli Delta

## REMOVED Requirements

### Requirement: Secret handling

The installer SHALL apply credentials only through a Kubernetes Secret and SHALL NOT print secret values.
Credentials never live in git, chart values committed to the repo, or command
output.

#### Scenario: Secrets applied as Kubernetes Secret
- **WHEN** `secrets.env` (path from `SECRETS_FILE`) exists with non-comment
  `KEY=VALUE` lines
- **THEN** the script creates/updates a Kubernetes Secret named
  `<release>-secrets` in the target namespace using
  `kubectl create secret --from-env-file` piped through a client-side dry run
  to `kubectl apply`, without printing any secret values

#### Scenario: Missing secrets file
- **WHEN** the secrets file does not exist
- **THEN** the script warns, skips Secret creation, and renders the release
  with `envFromSecret=""` so the pod does not wait on a missing Secret

#### Scenario: TLS secret applied from cert/key files
- **WHEN** ingress TLS is enabled and `INGRESS_TLS_CERT_FILE` and
  `INGRESS_TLS_KEY_FILE` both name readable PEM files
- **THEN** the script creates/updates the `kubernetes.io/tls` Secret named
  `INGRESS_TLS_SECRET_NAME` (default `<release>-tls`) in the target namespace
  using `kubectl create secret tls` piped through a client-side dry run to
  `kubectl apply`, without printing the certificate or key contents; in
  dry-run the pipeline is printed without file contents

#### Scenario: Half-specified or unreadable TLS files rejected
- **WHEN** only one of `INGRESS_TLS_CERT_FILE`/`INGRESS_TLS_KEY_FILE` is set,
  or a set path does not exist or is not readable
- **THEN** the script aborts with an error naming the variable and path

#### Scenario: TLS enabled without a certificate source
- **WHEN** ingress TLS is enabled but no cert/key files are set and
  `INGRESS_TLS_ISSUER` is empty
- **THEN** the script warns that the TLS Secret must be provisioned
  externally (or via cert-manager) and that the controller will serve its
  default self-signed certificate until then, and continues; in certificate
  mode the warning names `INGRESS_TLS_ISSUER` as the missing piece and notes
  that no Certificate resource is rendered without it

#### Scenario: Certificate resource delegated to cert-manager
- **WHEN** ingress TLS is enabled with `INGRESS_TLS_CERTIFICATE=true` and
  `INGRESS_TLS_ISSUER` set
- **THEN** the generated values enable the chart's cert-manager `Certificate`
  (`ingress.certificate`) with `issuerRef` (name from `INGRESS_TLS_ISSUER`,
  kind from `INGRESS_TLS_ISSUER_KIND`, `ClusterIssuer` when empty),
  `dnsNames` from `INGRESS_HOST` and
  `secretName` equal to the Ingress `tls` secret name (`<release>-tls`
  default); the `cert-manager.io/cluster-issuer` Ingress annotation is NOT
  rendered, so cert-manager does not create a second Certificate via the
  ingress shim
- **WHEN** `INGRESS_TLS_CERTIFICATE=true` but `INGRESS_TLS_ISSUER` is empty
- **THEN** no Certificate values are rendered and the missing-issuer warning
  is emitted

## ADDED Requirements

### Requirement: Credential handling

The installer SHALL apply credentials only through a Kubernetes Secret and SHALL NOT print secret values.
Credentials never live in git, chart values committed to the repo, or command
output.

#### Scenario: Secrets applied as Kubernetes Secret
- **WHEN** `secrets.env` (path from `SECRETS_FILE`) exists with non-comment
  `KEY=VALUE` lines
- **THEN** the script creates/updates a Kubernetes Secret named
  `<release>-secrets` in the target namespace using
  `kubectl create secret --from-env-file` piped through a client-side dry run
  to `kubectl apply`, without printing any secret values

#### Scenario: Missing secrets file
- **WHEN** the secrets file does not exist
- **THEN** the script warns, skips Secret creation, and renders the release
  with `envFromSecret=""` so the pod does not wait on a missing Secret

### Requirement: Ingress TLS certificate issuance

Ingress TLS certificates SHALL be issued exclusively by cert-manager: the
installer never applies a TLS Secret outside the chart's `Certificate`
resource, and never renders a self-signed fallback.

#### Scenario: Certificate issued via cert-manager only
- **WHEN** ingress TLS is enabled with `INGRESS_TLS_ISSUER` set
- **THEN** the generated values enable the chart's cert-manager `Certificate`
  (`ingress.certificate`) with `issuerRef` (name from `INGRESS_TLS_ISSUER`,
  kind from `INGRESS_TLS_ISSUER_KIND`, `ClusterIssuer` when empty), `dnsNames`
  (see below) and `secretName` equal to the Ingress `tls` secret name
  (`INGRESS_TLS_SECRET_NAME`, default `<release>-tls`); the
  `cert-manager.io/cluster-issuer` Ingress annotation is never rendered, so
  cert-manager issues exactly one Certificate. No `kubernetes.io/tls` Secret
  is created outside the Certificate resource

#### Scenario: TLS requires an issuer
- **WHEN** `INGRESS_TLS_ENABLED=true` with an empty `INGRESS_TLS_ISSUER`
- **THEN** the script aborts with an error naming `INGRESS_TLS_ISSUER` (the
  chart's Certificate requires an issuer name; there is no renderable
  half-state and no fallback certificate)

#### Scenario: Certificate DNS names configurable (wildcards)
- **WHEN** `INGRESS_TLS_DNS_NAMES` is set (comma-separated)
- **THEN** the Certificate renders those names verbatim as `dnsNames`,
  enabling wildcards (`INGRESS_TLS_DNS_NAMES="*.example.com,example.com"`)
  and multi-domain certificates
- **WHEN** `INGRESS_TLS_DNS_NAMES` is empty
- **THEN** `dnsNames` falls back to `INGRESS_HOST` (omitted when that is
  empty too — catch-all rule)

## MODIFIED Requirements

### Requirement: Cluster bootstrap

The project SHALL ship a script that bootstraps cluster access from the
client host and generates a cluster-aware installer configuration, so that
`helm`/`kubectl` work and `install.sh`/`update.sh` run without manual
configuration.

#### Scenario: Kubeconfig fetched from the control plane
- **WHEN** the script runs with `--host [user@]control-plane`
- **THEN** it fetches the k3s kubeconfig (`/etc/rancher/k3s/k3s.yaml` by
  default) via scp, falling back to `ssh host "sudo cat ..."` when the file is
  not directly readable, rewrites any `127.0.0.1`/`localhost` server URL to
  the control-plane address (preserving the port), installs it at the
  kubeconfig destination with mode 600, and validates cluster access with
  `kubectl get nodes` before proceeding

#### Scenario: Passwordless SSH to the control plane
- **WHEN** the script runs with `--host` and the local SSH key is missing
- **THEN** it generates an ed25519 key without passphrase, installs the public
  key into the control-plane host's `~/.ssh/authorized_keys` idempotently (no
  duplicates on re-run), first trying key-based (batch) auth and falling back
  to one interactive authentication, and verifies that passwordless SSH works
  before fetching anything

#### Scenario: Cluster review derives chart values
- **WHEN** the cluster is reachable and no ingress controller exists
- **THEN** the script derives values compatible with the cluster: node
  architecture (empty + warning when nodes are mixed-arch), the default
  storage class, LoadBalancer capability (assigned LoadBalancer ingress IPs or
  an `svclb` DaemonSet) with a NodePort fallback otherwise, the live release's
  image tag when the release already exists, the existing PVC's size and
  storage class, and the control-plane timezone (when SSH was used)

#### Scenario: Existing release state wins
- **WHEN** a Helm release with the configured name already exists in the
  namespace
- **THEN** `IMAGE_TAG` is taken from the live release (not the chart default)
  and `STORAGE_SIZE`/`STORAGE_CLASS` come from the existing PVC so an update
  never shrinks or moves storage

#### Scenario: Ingress controller defaults the ingress on
- **WHEN** an IngressClass is present on the cluster (Traefik preferred)
- **THEN** the generated configuration defaults `INGRESS_ENABLED=true` with
  the detected class, `INGRESS_TLS_ENABLED=true`,
  `INGRESS_TLS_SECRET_NAME=<release>-tls`,
  `INGRESS_TRUSTED_PROXIES=10.42.0.0/16` (k3s default pod CIDR, documented as
  adjustable), and `SERVICE_TYPE=ClusterIP` — the ingress fronts the pod
  service, so the LoadBalancer/NodePort derivation and the NodePort fallback
  do not apply (`NODE_PORT` is cleared) — leaving `INGRESS_HOST` empty for a
  catch-all rule
- **AND WHEN** the `certificates.cert-manager.io` CRD is present
- **THEN** the script reports that cert-manager issues the certificates and
  that setting `INGRESS_TLS_ISSUER` (with optional `INGRESS_TLS_ISSUER_KIND`)
  enables issuance
- **WHEN** the CRD is absent
- **THEN** the script warns that cert-manager is missing and the certificate
  will not be issued until it is installed
- **WHEN** no ingress controller is detected
- **THEN** the ingress and its TLS settings stay disabled and the
  LoadBalancer/NodePort derivation applies as before

#### Scenario: .env generated with backup
- **WHEN** configuration is written
- **THEN** an existing `.env` is first backed up to
  `.env.backup-<timestamp>` (`.N`-suffixed on same-second collisions), the new
  `.env` contains every variable from
  `.env.example` with cluster-derived values, every written value is checked
  to be YAML/shell-safe, and values containing spaces are double-quoted

#### Scenario: Secrets scaffolded without leaking values
- **WHEN** the secrets file is missing
- **THEN** it is scaffolded from `secrets.env.example` with mode 600; when it
  exists, only its key *names* are reported (cluster secret keys too), never
  any value

#### Scenario: Review-only mode
- **WHEN** the script runs without `--host` and kubectl already works
- **THEN** the SSH/fetch stages are skipped and only the review and
  configuration stages run

#### Scenario: Unusable kubeconfig is fatal
- **WHEN** the fetched kubeconfig does not validate against the cluster
  (`kubectl get nodes` fails)
- **THEN** the script aborts with a hint about the k3s `--tls-san` setting
  and the kubeconfig file is left in place for inspection

#### Scenario: End state ready for the installers
- **WHEN** the script completes successfully
- **THEN** `kubectl` and `helm` work against the cluster using the generated
  kubeconfig, `.env` is complete for `install.sh`/`update.sh`, the printed
  next steps name those scripts, and `--install` chains directly into
  `scripts/install.sh`

### Requirement: Generated values safety

The installer SHALL reject unsafe values before writing the generated values file.
Environment values are interpolated into a rendered values file.

#### Scenario: Unsafe value rejected
- **WHEN** a variable used in the generated values file contains quotes,
  backslashes, or newlines
- **THEN** the script aborts with a clear error naming the variable instead of
  producing broken YAML

#### Scenario: Ingress-fronted service is ClusterIP
- **WHEN** `INGRESS_ENABLED=true` and `SERVICE_TYPE` is set to anything other
  than `ClusterIP`
- **THEN** the script aborts with an error explaining that the ingress fronts
  the pod service and suggesting `SERVICE_TYPE=ClusterIP` or
  `INGRESS_ENABLED=false`
- **WHEN** `INGRESS_ENABLED=true` and `SERVICE_TYPE` is empty
- **THEN** `service.type: "ClusterIP"` is rendered (never the chart's
  LoadBalancer default)
- **WHEN** the ingress is disabled
- **THEN** the LoadBalancer/NodePort service types render as configured
