# CloudForge — A Local DevOps Platform

**CloudForge** is a portfolio project demonstrating how a containerized Flask/PostgreSQL application can be provisioned, deployed, monitored, and recovered using an integrated DevOps toolchain. It runs on a **single-node K3s cluster inside an Ubuntu Server VirtualBox VM**, with a separate, disposable VM used to test bootstrap automation.

> **Project scope:** A hands-on, production-inspired learning environment, **not** a production-ready highly available platform. The infrastructure, backup workflows, and recovery procedures have been tested in the specific ways described below; cloud failover and complete VM-loss recovery have not been demonstrated.

## Architecture

```text
Windows host (VirtualBox + Vagrant)
  ├── Disposable Ubuntu test VM
  │     └── Ansible bootstrap → K3s installation → node Ready
  │
  └── Main Ubuntu Server VM (single-node K3s)
        ├── Terraform → dedicated cloudforge-managed namespace
        ├── Helm release (devops-helm) → PostgreSQL StatefulSet + PVC,
        │                             Services, ConfigMaps, Flask PDB
        ├── GitHub Actions CD → Flask Deployment (2 replicas)
        │     GitHub repo → tests → GHCR image → Trivy → restricted runner → rollout
        ├── Docker Compose monitoring
        │     Prometheus ← Flask /metrics + Node Exporter
        │     Grafana ← Prometheus; Alloy → Loki ← K3s Flask logs
        │     Alertmanager ← Prometheus alert rules
        └── systemd timer → pg_dump archive → restricted export directory
                                         └── Windows scheduled PowerShell pull
                                              via SSH/SCP + SHA-256 verification
```

**Ownership is deliberately separated:** Helm owns six infrastructure resources; GitHub Actions updates the Flask Deployment image; Terraform owns its dedicated namespace. This avoids the Helm/server-side-apply ownership conflict previously encountered when Helm and `kubectl set image` both updated the Flask Deployment.

For architecture notes, see [`docs/architecture.md`](docs/architecture.md) (to be completed).

## Technology stack

| Layer | Tools | Role |
| --- | --- | --- |
| Virtualization | VirtualBox, Vagrant | Local Ubuntu VM and reproducible bootstrap test |
| Configuration management | Ansible | OS packages and K3s installation |
| Infrastructure as code | Terraform, Kubernetes provider | A separate Kubernetes namespace |
| Orchestration | K3s, Helm | PostgreSQL and supporting resources |
| App delivery | GitHub Actions, GHCR, Trivy | Tests, image build, security scan and Flask rollout |
| Metrics | Prometheus, Node Exporter, Grafana | Flask availability, request rate, P95 latency, HTTP 5xx |
| Logs | Grafana Alloy, Loki | Kubernetes Flask logs collected from node files |
| Backup & recovery | PostgreSQL `pg_dump`/`pg_restore`, systemd, SSH/SCP, PowerShell | Local daily backups and Windows off-VM copies |

## Related repositories

- **Application source and CI/CD:** [vec1or/demo-app](https://github.com/vec1or/demo-app)
- **Earlier Kubernetes learning project:** [vec1or/kubernetes-flask-postgres](https://github.com/vec1or/kubernetes-flask-postgres)

CloudForge is the **infrastructure and operations repository**; the Flask application and its GitHub Actions workflow remain in the separate `demo-app` repository.

## Repository layout

```text
cloudforge/
├── infrastructure/
│   ├── Vagrantfile
│   ├── ansible/
│   │   ├── bootstrap.yml
│   │   ├── install-k3s.yml
│   │   └── inventory.ini
│   ├── terraform/
│   │   ├── main.tf
│   │   ├── provider.tf
│   │   ├── versions.tf
│   │   └── .terraform.lock.hcl
│   └── systemd/
│       ├── cloudforge-postgres-backup.service
│       └── cloudforge-postgres-backup.timer
├── kubernetes/
│   ├── app/flask-deployment.yaml
│   ├── helm/demo-app-chart/
│   └── migration-lab/
├── monitoring/
│   ├── compose.yaml
│   ├── prometheus.yml
│   ├── alerts.yml
│   ├── alertmanager.yml
│   ├── config.alloy
│   ├── loki-config.yaml
│   └── grafana/
│       ├── dashboards/cloudforge-dashboard.json
│       └── provisioning/
├── scripts/backup-postgres.sh
├── docs/
│   ├── architecture.md
│   └── disaster-recovery.md
└── README.md
```

## What has been tested

- **Vagrant/Ansible/K3s:** provisioned a disposable Ubuntu 24.04 VM; K3s `v1.36.5+k3s1` started, node reported `Ready`, and system components became healthy. A repeat provision run reported no changes for the shown playbook; this is not a full clean-room reproducibility guarantee.
- **Terraform:** applied the `cloudforge-managed` namespace and confirmed a subsequent `terraform plan` returned **No changes**.
- **Deployment separation:** migrated Flask Deployment out of the Helm release without replacing its UID; Helm remained at revision 13 after a subsequent CD-driven Flask image rollout.
- **Monitoring:** Prometheus returned `up{job="flask-app"} = 1`; Grafana displayed four application panels. Alloy forwarded actual Flask logs from K3s/containerd log files into Loki.
- **Backup/restore:** a PostgreSQL 17 custom-format dump was created; an archive copied to Windows and back passed SHA-256 comparison and was restored into an isolated test database with its `messages` table and one row intact.
- **Scheduling:** the Linux systemd backup service succeeded; its daily timer was enabled. A Windows Scheduled Task was configured and manually invoked successfully. **Unattended execution at the scheduled time has not yet been observed.**

## Getting started (local lab)

These are **guided starting points**, not a one-command reconstruction of the entire main environment. Choose a disposable test environment first, and review the configurations before applying them.

### 1. Create a disposable K3s VM (Windows host)

Install VirtualBox and Vagrant on Windows. From a **Windows** terminal in the `infrastructure` directory:

```powershell
vagrant validate
vagrant up --provider=virtualbox
vagrant ssh
```

Inside the guest:

```bash
sudo systemctl is-active k3s
sudo k3s kubectl get nodes
```

The Vagrant VM is configured for approximately **2 GiB RAM / 2 vCPU**. Check host memory first; avoid running it simultaneously with the main VM if resources are limited. The box must be downloadable, and bootstrap automation requires network access. See the Ansible files for the pinned K3s version and installation procedure.

> Do not run Vagrant from inside the K3s VM. The Vagrantfile is intended for the Windows host running VirtualBox.

### 2. Review Terraform (existing main K3s VM)

```bash
cd infrastructure/terraform
terraform init
terraform validate
```

The example provider expects a **local K3s kubeconfig** at `/etc/rancher/k3s/k3s.yaml`, which is privileged and typically readable only by root. Review the plan and credentials before applying:

```bash
sudo terraform plan
# Only after reviewing the plan:
# sudo terraform apply
```

Terraform manages the standalone `cloudforge-managed` namespace, **not** the application or Helm-owned resources. Do not commit `terraform.tfstate`, credentials, or Terraform variable secrets. The current local state backend is intended for the lab and is not suitable for team collaboration.

### 3. Helm-managed infrastructure and Flask Deployment

The existing main environment uses namespace `devops-helm`:

```bash
helm status demo-app -n devops-helm
sudo k3s kubectl get deployment,statefulset,service,pvc -n devops-helm
```

The Helm chart supports disabling the Flask Deployment template:

```bash
helm template demo-app ./kubernetes/helm/demo-app-chart \
  -n devops-helm --set flask.deployment.enabled=false
```

**Do not blindly run `helm upgrade` on an existing cluster.** This project deliberately separated Flask Deployment ownership from Helm after migrating a live resource using a verified `helm.sh/resource-policy: keep` sequence. A fresh deployment must provision database credentials securely, install the infrastructure chart with the desired settings, and separately apply/deploy the Flask manifest. The actual release's values and CD process must agree on image tags and configuration.

The application pipeline is defined in the [demo-app repository](https://github.com/vec1or/demo-app). Its self-hosted runner uses namespace-scoped Kubernetes RBAC; do **not** give it cluster-admin kubeconfig credentials.

### 4. Start monitoring

On the Ubuntu VM, create a local **untracked** `monitoring/.env` file containing:

```dotenv
GRAFANA_ADMIN_PASSWORD=<set-a-strong-local-password>
```

From `monitoring/`:

```bash
docker compose config --quiet
docker compose up -d
```

Prometheus is exposed on `127.0.0.1:9090`, Grafana on `127.0.0.1:3000`, and Loki on `127.0.0.1:3100` on the Ubuntu VM. If connecting from Windows, use an SSH local port-forward (for example `ssh -p 2222 -L 3000:127.0.0.1:3000 devops@127.0.0.1`).

**Lab-specific configuration to review before reuse:**

- `monitoring/prometheus.yml` currently scrapes Flask via the K3s Service ClusterIP `10.43.60.214:5000`, which may change when the Service is recreated.
- `monitoring/config.alloy` reads node-level `/var/log/pods` and the Docker socket. Running Alloy with elevated permissions and Docker socket access is a **security compromise for this single-node lab**, not a production recommendation.
- Grafana dashboards and data sources are provisioned from files. Ensure the data source UIDs in dashboards and provisioning files remain consistent.
- Alertmanager readiness has been checked, but notification delivery and alert firing have **not** been end-to-end validated.

### 5. Backup and disaster recovery

Daily local backups use:

- systemd unit: `infrastructure/systemd/cloudforge-postgres-backup.service`
- timer: `infrastructure/systemd/cloudforge-postgres-backup.timer`
- script: `scripts/backup-postgres.sh`
- local archives: `/var/backups/cloudforge/postgres/`
- readable export copies: `/var/backups/cloudforge-export/` (restricted group)
- Windows off-VM archive location: `D:\CloudForge-Backups\`

The Windows pull script (`sync-backups.ps1`) and Task Scheduler job were tested on the Windows host; **the PowerShell script is not yet part of this repository**. Follow [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the tested logical restore process and limitations. Backups contain application data; restrict their access. Never commit backup archives.

## Security and operational limitations

- Single-node K3s and local-path PVC: **no node-level high availability**.
- Two Flask replicas protect against some Pod failures, not loss of the entire VM.
- Backup targets of **RPO 24 hours / RTO 2 hours** are **objectives**, not demonstrated guarantees. Only isolated database restore has been exercised, not full VM-loss recovery.
- Off-VM copies on the Windows host do not protect against failure of that host or disk.
- Automatic off-VM transfer depends on Windows being awake, SSH being available, and the Ubuntu VM being reachable; fresh daily delivery must be monitored.
- Retention policy and off-host copy confirmation should be coordinated before re-enabling destructive cleanup.
- Terraform currently uses local state and a privileged kubeconfig for lab operations.
- Alloy's root/Docker socket access, fixed Prometheus ClusterIP, and missing independently validated alert notifications are hardening tasks.
- Production requirements such as TLS, secret management, remote state, multi-node failover, independent backups, resource sizing and comprehensive security review remain outside the tested scope.

## Next improvements

1. Replace the hard-coded Prometheus ClusterIP with durable service discovery or a supported network endpoint.
2. Restrict Alloy's access and validate Grafana provisioning against an empty database.
3. Add the Windows backup pull script to the repository after removing host-specific identifiers, and test unattended scheduler execution, retention, and alerting on failure.
4. Run a timed complete environment rebuild/restore drill to measure actual RPO and RTO.
5. Move Terraform state to an appropriate secure backend before collaboration.
6. Add screenshots, architecture diagrams, and automated smoke-test evidence to the portfolio.

## License

No license has been selected yet. Add an appropriate `LICENSE` before inviting reuse or contributions.
