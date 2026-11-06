# homeassistant-chart Specification

## Purpose
A Helm chart that deploys Home Assistant (official container image) on any
Kubernetes 1.25+ cluster with defaults tuned for k3s on Raspberry Pi 4 nodes:
single replica, persistent `/config`, environment-driven configuration and
k3s-friendly exposure.

## Requirements

### Requirement: Single-replica stateful workload

The chart MUST render exactly one replica of the workload at all times.
Home Assistant keeps session, recorder and entity state in `/config` and must
never run concurrently at more than one replica.

#### Scenario: Default render
- **WHEN** the chart is rendered with default values
- **THEN** it renders a StatefulSet with `replicas: 1`, a headless service as
  `serviceName`, and `terminationGracePeriodSeconds >= 60` so Home Assistant
  can flush the recorder database on shutdown

### Requirement: Persistent /config storage

The chart MUST mount persistent storage at /config whenever persistence is enabled.
The pod mounts a persistent volume at `/config` (Home Assistant's state
directory).

#### Scenario: Default persistence
- **WHEN** `persistence.enabled=true` (the default) and no `existingClaim` is set
- **THEN** the chart renders a PVC (default 5Gi, ReadWriteOnce, cluster-default
  storage class) and mounts it at `/config`

#### Scenario: Persistence disabled
- **WHEN** `persistence.enabled=false`
- **THEN** the pod gets an `emptyDir` volume at `/config` and no PVC is rendered

#### Scenario: Bring your own claim
- **WHEN** `persistence.existingClaim` is set
- **THEN** no PVC is rendered and the named claim is mounted at `/config`

### Requirement: Environment-driven configuration

The chart MUST deliver all runtime configuration through environment variables and MUST NOT render secret material into ConfigMaps.
All runtime configuration reaches the container through environment variables;
no secret material may be rendered into ConfigMaps or plain values.

#### Scenario: Timezone
- **WHEN** the chart is rendered with `timezone: Europe/Berlin`
- **THEN** the container receives `TZ=Europe/Berlin`

#### Scenario: External secret reference
- **WHEN** `envFromSecret` names a Secret (default `<release>-secrets`)
- **THEN** the pod's environment is populated with `envFrom` referencing that
  Secret so Home Assistant can read each key with `!env_var`

#### Scenario: Chart-managed secret values
- **WHEN** `secretEnv` is a non-empty map of KEY/VALUE pairs
- **THEN** the chart renders a Secret with those pairs and adds it to `envFrom`

#### Scenario: Extra environment
- **WHEN** `extraEnv` (list of env entries) or `extraEnvFrom` (list of
  envFrom sources) is set
- **THEN** the entries are rendered into the container environment

### Requirement: First-boot bootstrap configuration

The chart MUST seed a working configuration on first boot and MUST NOT overwrite an existing configuration.
A freshly provisioned `/config` must yield a working Home Assistant without
manual YAML editing, without ever overwriting an existing configuration.

#### Scenario: Empty config volume
- **WHEN** the pod starts and `/config/configuration.yaml` does not exist
- **THEN** a minimal working `configuration.yaml` (from the chart's
  `bootstrapConfig.configuration`, rendered via a ConfigMap) is copied into
  `/config` by an init container, and the config documents the `!env_var`
  pattern for secrets

#### Scenario: Existing configuration
- **WHEN** `/config/configuration.yaml` already exists
- **THEN** the init container leaves `/config` untouched

#### Scenario: Trusted-proxy seed behind an ingress
- **WHEN** ingress is enabled and `ingress.trustedProxies` is a non-empty
  list of CIDRs
- **THEN** the seeded configuration also contains
  `http.use_x_forwarded_for: true` and `http.trusted_proxies` with those
  CIDRs, so logins through the reverse proxy are accepted

#### Scenario: No trusted proxies without ingress
- **WHEN** ingress is disabled or `ingress.trustedProxies` is empty
- **THEN** no `http:` section is added to the seeded configuration

### Requirement: Health probes

The chart MUST define startup, readiness and liveness probes.
The workload must be guarded against slow first boot and deadlocked runtime.

#### Scenario: Startup probe
- **WHEN** the container starts
- **THEN** a startup probe against the frontend path (HTTP 200 without
  authentication) tolerates at least 5 minutes of startup before liveness
  checks begin

#### Scenario: Runtime probes
- **WHEN** the container is running
- **THEN** readiness and liveness probes poll the same unauthenticated frontend
  path

### Requirement: Service exposure

The chart MUST expose the frontend through a Service.
The frontend must be reachable in a k3s cluster with sane defaults.

#### Scenario: Default LoadBalancer service
- **WHEN** `service.type=LoadBalancer` (the default)
- **THEN** a Service exposes `service.port` (default 8123) to the cluster
  load balancer (k3s klipper-lb binds the node IP)

#### Scenario: NodePort alternative
- **WHEN** `service.type=NodePort` and `service.nodePort` is set
- **THEN** the Service is rendered with that nodePort

#### Scenario: Static load balancer IP
- **WHEN** `service.loadBalancerIP` is set
- **THEN** the Service is rendered with that IP

### Requirement: Raspberry Pi 4 friendliness

The chart defaults MUST suit Raspberry Pi 4 nodes without blocking larger clusters.
Defaults must suit 4GB Raspberry Pi 4 nodes running k3s, without blocking
larger clusters.

#### Scenario: Resource defaults
- **WHEN** the chart is rendered with default values
- **THEN** requests are about 200m CPU / 512Mi memory, the memory limit is
  about 1.5Gi, and no CPU limit is set (CPU limits throttle Home Assistant
  startup on Pi-class nodes)

#### Scenario: arm64 scheduling pin
- **WHEN** `nodeSelector` includes `kubernetes.io/arch: arm64` (via values)
- **THEN** the pod is scheduled only on arm64 nodes

#### Scenario: Discovery via host network
- **WHEN** `hostNetwork=true`
- **THEN** the pod uses the host network with `dnsPolicy: ClusterFirstWithHostNet`
  to enable mDNS/SSDP/UPnP discovery

#### Scenario: USB radios
- **WHEN** `usbDevices` lists hostPath entries (e.g. `/dev/ttyUSB0` for a
  Zigbee/Z-Wave stick)
- **THEN** each entry is mounted as a hostPath device volume at the same path
  inside the container

### Requirement: Optional ingress

The chart MUST render an Ingress only when enabled.
Ingress is opt-in and standard.

#### Scenario: Ingress disabled by default
- **WHEN** `ingress.enabled=false` (the default)
- **THEN** no Ingress is rendered

#### Scenario: Ingress enabled
- **WHEN** `ingress.enabled=true`
- **THEN** an Ingress is rendered with `className`, `annotations`, `hosts` and
  optional `tls` from values

#### Scenario: Catch-all rule without a host
- **WHEN** a `hosts` entry has an empty or absent `host`
- **THEN** the rendered rule omits the `host` key entirely (never
  `host: ""`), so the rule matches any hostname reaching the ingress
  controller

#### Scenario: TLS block from values
- **WHEN** `ingress.tls` is a non-empty list of entries (e.g.
  `secretName` with an optional `hosts` list)
- **THEN** the Ingress renders the `tls` block verbatim from values

### Requirement: Chart packaging quality

The chart MUST pass helm lint and helm template with default values.
The chart must be lint-clean and self-describing.

#### Scenario: Lint and template
- **WHEN** `helm lint` and `helm template` run on the chart with default values
- **THEN** both succeed without errors

#### Scenario: Metadata
- **WHEN** the chart is inspected
- **THEN** `Chart.yaml` declares `appVersion` equal to the default image tag
  and the chart version follows semver

### Requirement: Cert-manager TLS certificate

The chart MUST be able to create the ingress TLS certificate via cert-manager,
and the Ingress MUST reference the Secret cert-manager maintains.
Certificate issuance and renewal are delegated to cert-manager through an
explicit `Certificate` resource; the chart renders it only when opted in.

#### Scenario: Certificate disabled by default
- **WHEN** `ingress.certificate.enabled=false` (the default)
- **THEN** no Certificate resource is rendered

#### Scenario: Certificate rendered
- **WHEN** `ingress.certificate.enabled=true` with
  `ingress.certificate.issuerRef.name` set
- **THEN** a `cert-manager.io/v1` Certificate is rendered with
  `spec.secretName` (`ingress.certificate.secretName`, default
  `<fullname>-tls`), `spec.issuerRef` (name and kind; kind defaults to
  `ClusterIssuer`, never cert-manager's own namespaced-`Issuer` default) and
  `spec.dnsNames` from `ingress.certificate.dnsNames`, falling back to the
  non-empty `ingress.hosts` entries

#### Scenario: Wildcard DNS names
- **WHEN** `ingress.certificate.dnsNames` contains a wildcard entry (e.g.
  `*.example.com`)
- **THEN** it renders verbatim (quoted, so YAML stays valid) and cert-manager
  issues the wildcard certificate (the issuer must be DNS-01 capable — the
  chart places no restriction)

#### Scenario: Issuer name required
- **WHEN** `ingress.certificate.enabled=true` without
  `ingress.certificate.issuerRef.name`
- **THEN** rendering fails with an error naming the missing value

#### Scenario: Ingress uses the certificate Secret
- **WHEN** the Certificate's `secretName` and an Ingress `tls` entry name the
  same Secret
- **THEN** the Ingress `tls` block references that Secret, so cert-manager's
  issuance and renewal serve the ingress directly
