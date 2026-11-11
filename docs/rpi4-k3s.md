# Raspberry Pi 4 + k3s node preparation

Target: one or more Raspberry Pi 4 (4GB/8GB) nodes running k3s, deployed with
this repository's chart. The chart itself is architecture-neutral; these steps
make the *nodes* solid.

## 1. Operating system

- Flash **64-bit** Raspberry Pi OS Lite (Bookworm or newer) or Ubuntu Server
  24.04 arm64 with the Raspberry Pi Imager. Verify with `uname -m` → `aarch64`.
- Enable SSH in the Imager and set a static IP or DHCP reservation per node —
  k3s nodes need stable addresses.

## 2. Storage: boot from SSD

Strongly recommended. SD cards wear out fast under k3s (etcd + container
writes). Use a USB-attached SSD via a powered hub or the Pi 4's USB 3 ports.
Raspberry Pi Imager can set `USB boot` directly, or boot the SD once and
`rpi-eeprom-update` to a USB-boot-capable EEPROM, then clone to SSD.

## 3. Enable cgroups (required for resource limits/metrics)

k3s needs the `memory` and `cpuset` cgroups enabled for kubelet resource
accounting:

- Bookworm+ (path `/boot/firmware/cmdline.txt`) or older OSes
  (`/boot/cmdline.txt`): append to the **single existing line**:

  ```text
  cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
  ```

- Reboot and verify: `cat /proc/cgroups | grep -E 'memory|cpuset'`
  (or `k3s kubectl describe node <node>` shows allocatable memory).

## 4. Time sync

The Pi has no battery-backed RTC. Ensure NTP works (systemd-timesyncd or
chrony) — wrong clocks break TLS and Home Assistant scheduling.

## 5. Install k3s

Server (first node):

```bash
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```

Additional agents:

```bash
# on the server, read the join token:
sudo cat /var/lib/rancher/k3s/server/node-token
# on each agent node:
curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 \
  K3S_TOKEN=<token> sh -s -
```

Notes:

- k3s bundles Traefik (ingress) and local-path (storage) and klipper-lb
  (LoadBalancer) — all three are what this project's chart defaults assume.
- Verify: `kubectl get nodes -o wide` (run `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
  on the server, or copy the file to your admin machine and replace
  `127.0.0.1` with the server IP).

## 6. Point your admin machine at the cluster

```bash
scp <user>@<server-ip>:/etc/rancher/k3s/k3s.yaml ./kubeconfig
sed 's/127.0.0.1/<server-ip>/' kubeconfig > ~/.kube/ha-config   # macOS: sed -i '' form
export KUBECONFIG=~/.kube/ha-config
kubectl get nodes
```

Or set `KUBECONFIG=/path/to/kubeconfig` in this repo's `.env` — the installer
scripts honor it.

## 7. Storage options

| Option | When | Setup |
| --- | --- | --- |
| `local-path` (k3s default) | single server node, simplest | nothing — chart default (`STORAGE_CLASS=` empty) |
| **Longhorn** | replicated storage across 2+ nodes, survives node loss | `kubectl apply -f longhorn.yaml` per [docs](https://longhorn.io/docs/); needs ~512Mi RAM/node — comfortable on 8GB nodes, tight on 4GB |

Then set `STORAGE_CLASS=longhorn` in `.env` before installing.

## 8. Hardware passthrough (Zigbee/Z-Wave radios)

1. Find a stable device path: `ls /dev/serial/by-id/` (preferred over
   `/dev/ttyUSB0`, which can change across reboots).
2. On the node, allow the container runtime to see the device (default k3s
   config is sufficient for hostPath device volumes).
3. In the chart values (via an extra values file referenced by `VALUES_EXTRA`
   in `.env`):

   ```yaml
   usbDevices:
     - name: zigbee
       hostPath: /dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0...
       type: CharDevice
   ```

## 9. Discovery (mDNS/UPnP) caveat

Multicast discovery on Kubernetes is unreliable across bridge interfaces.
If you need it, set `HOST_NETWORK=true` in `.env` (the chart then pins the pod
to a node's host network with `dnsPolicy: ClusterFirstWithHostNet`). For most
setups, MQTT-based discovery or an ESPHome-style integration is more robust.

## 10. Node sizing guidance

| Cluster | Recommendation |
| --- | --- |
| 1× Pi4 4GB | fine for HA + local-path; skip Longhorn; keep recorder DB small (or external DB) |
| 2-3× Pi4 8GB | comfortable: Longhorn replicated PVC, external Postgres on the cluster, Traefik ingress |
| any | `resources` in the chart already fit 4GB nodes; tune via `.env`/extra values, not chart edits |
