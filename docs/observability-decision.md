# Observability Stack Decision: Prometheus + Loki + Alertmanager

## Context

The lab needs production-grade observability across all hypervisors and
guest VMs.  The stack must:

- Collect metrics from every VM (Linux + Windows) and every
  hypervisor (Proxmox + Hyper-V + VMware Workstation)
- Centralise logs from every VM and hypervisor
- Alert via Discord webhook (existing pattern from v1.4 bootstrap)
- Be deployable with the existing `labctl.py` + `lab.yaml` workflow
- Have an integration test against a fake stack

## Options

| Stack | Pros | Cons |
|-------|------|------|
| **Prometheus + node_exporter + Loki + Alertmanager (THIS CHOICE)** | Native K8s/VM support; PromQL is the industry standard; Loki reuses Prometheus labels; Alertmanager native; zero cost | Prometheus not HA by default (acceptable for lab); Loki scales differently than Elasticsearch |
| Prometheus + Grafana + Elasticsearch (ELK) | Mature log stack | ES resource-heavy; two query languages (PromQL + Lucene); overkill for lab |
| Prometheus + Grafana + Grafana Tempo | Unified traces + metrics + logs in Grafana | Tempo traces only; still need Loki for logs |
| Telegraf + InfluxDB + Flux | Single binary for metrics | Not Prometheus-native; Flux is less common than PromQL |
| Datadog / New Relic / Splunk | SaaS, zero ops | Cost; vendor lock-in; not self-hosted |

## Decision: Prometheus + node_exporter + Loki + Alertmanager

**Metrics:** Prometheus (scrapes node_exporter on every Linux VM, wmi_exporter on every Windows VM, pve_exporter on Proxmox nodes, and the Windows exporter on Hyper-V hosts).

**Logs:** Loki (Promtail agents on every VM + hypervisor; labels match Prometheus labels so dashboards correlate metrics + logs).

**Alerting:** Alertmanager (routes to Discord webhook via existing `scripts/bash/alert-discord.sh` pattern from v1.4 bootstrap).

**Dashboards:** Grafana (provisioned via JSON in `docs/grafana-dashboards/`).

## Deployment Model

- **Prometheus + Alertmanager + Loki + Grafana** run as a single **observability VM** on the Synology NAS (same host as PBS, leveraging the same UPS/ECC/dedup).
- The observability VM gets a static IP on the management VLAN (e.g., `10.10.20.6/24`).
- Exporters / Promtail run as systemd services on every guest VM and hypervisor.
- `labctl.py` drives the whole stack: `labctl observability-init --execute` brings up the observability VM, `labctl exporter-deploy --execute` pushes exporter configs to all targets.

## `lab.yaml` Extension

```yaml
observability:
  host: 10.10.20.6
  ssh_user: root
  ssh_key: /etc/lab/ssh_key
  # The stack is deployed as a docker-compose stack on the observability VM
  compose_file: /opt/observability/docker-compose.yml

exporters:
  linux:
    image: prom/node-exporter:v1.8.2
    port: 9100
  windows:
    image: prom/wmi-exporter:v0.17.0
    port: 9182
  pve:
    image: prometheuscommunity/pve-exporter:v0.9.0
    port: 9221
  hyperv:
    # uses the same wmi_exporter on the Hyper-V host
    image: prom/wmi-exporter:v0.17.0
    port: 9182

log_agents:
  linux:
    image: grafana/promtail:3.1.0
  windows:
    image: grafana/promtail:3.1.0
```

## Integration Test Plan

- `lab-test/fake-observability/` Docker image with shims for `prometheus`, `loki`, `alertmanager`, `grafana`, and each exporter.
- Test fixture declares the stack in `lab.yaml`, runs `labctl observability-init --execute`, asserts the docker-compose stack is up, asserts exporter configs are pushed, asserts one alert fires and reaches the Discord webhook shim.
- 10-case test suite mirroring the PBS pattern.

## Consequences

- One more VM on the NAS (total: PBS + Observability = 2 VMs on NAS).  Acceptable — the NAS has 32 GB RAM, UPS, ECC, dedup.
- Exporter images are public Docker Hub images; no build step required.
- Loki + Prometheus share the same label set (`instance`, `job`, `hypervisor`, `vm`), so Grafana dashboards can link from a metric panel to the corresponding log stream.
- Alertmanager uses the existing Discord webhook URL stored in `secrets/discord-webhook.txt` (gitignored, deployed via `labctl secret-set`).