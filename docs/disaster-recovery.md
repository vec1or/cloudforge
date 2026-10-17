# CloudForge — Disaster Recovery Runbook

**Project:** CloudForge
**Environment:** Single-node K3s on Ubuntu Server in VirtualBox (Windows host)
**Database:** PostgreSQL 17 (`demoapp`)
**Application:** Flask, deployed from GHCR
**Status:** Educational / portfolio runbook; partial recovery validation only
**Last reviewed:** 2026-10-17

> **Safety first:** Never restore into the live `demoapp` database without an approved recovery window, a separately verified backup, and an explicit rollback plan. A local PostgreSQL restore test does **not** establish that the entire VM or cluster can be recovered within the target RTO.

## 1. Purpose and recovery objectives

This runbook covers diagnosis, backup, recovery, and validation for the CloudForge Flask + PostgreSQL application. The deployment currently runs on a **single Ubuntu Server VM**. Two Flask replicas improve resilience against a single application Pod failure, but do not provide VM-level or node-level high availability.

| Objective | Target | Validation status |
|---|---|---|
| RPO (maximum acceptable data loss) | 24 hours | **Target only.** Daily backup schedule exists, but continuous scheduling and off-host delivery have not been demonstrated over multiple days. |
| RTO (time to restore service) | 2 hours | **Target only.** End-to-end full VM-loss recovery has not been timed or tested. |

RPO depends on completed, accessible backups. RTO also depends on availability of the Windows host, the backup files, network access, VM provisioning, Kubernetes configuration, secrets, and GHCR images.

## 2. Current architecture and ownership

```text
Windows host (VirtualBox 7.2.6)
  ├── devops-server (Ubuntu Server; single-node K3s)
  │    ├── K3s namespace: devops-helm
  │    │    ├── Flask Deployment: demo-app-flask (2 replicas)
  │    │    ├── Flask Service: demo-app-flask-service
  │    │    └── PostgreSQL StatefulSet: demo-app-postgres
  │    │          └── local-path PVC: postgres-data-demo-app-postgres-0
  │    ├── Terraform-managed namespace: cloudforge-managed
  │    ├── Monitoring: Docker Compose (Prometheus, Grafana, Loki, Alloy,
  │    │   Alertmanager, Node Exporter)
  │    └── systemd PostgreSQL backup service + daily timer
  │           ├── /var/backups/cloudforge/postgres (root-only)
  │           └── /var/backups/cloudforge-export (group-readable export)
  └── D:\CloudForge-Backups (copied by Windows Scheduled Task over SSH)
```

**Management boundaries:**

| Component | Source of truth / manager |
|---|---|
| Ubuntu VM provisioning | `infrastructure/Vagrantfile` + Ansible playbooks; tested on a separate test VM |
| Ubuntu packages and K3s installation | `infrastructure/ansible/` |
| Namespace `cloudforge-managed` | `infrastructure/terraform/` |
| PostgreSQL StatefulSet, Services, ConfigMaps, Flask PDB | Helm release `demo-app` in `devops-helm`, **infrastructure-only chart** |
| Flask Deployment image | GitHub Actions using restricted Kubernetes access (`kubectl set image`) |
| Prometheus, Grafana, Loki, Alloy, Alertmanager | `monitoring/compose.yaml` |
| Database backup | `scripts/backup-postgres.sh` and `infrastructure/systemd/` |
| Off-VM sync | Windows PowerShell `sync-backups.ps1` + Task Scheduler |

**Important:** Helm release revision **13** was verified in the learning environment to contain six infrastructure resources and **no Flask Deployment**. Revision numbers are historical observations, not a fixed desired state; always verify the live release before acting. Do **not** use `helm rollback` to undo a Flask image deployment.

## 3. Backup design

### 3.1 Source and format

The system backs up PostgreSQL database `demoapp` from Pod `demo-app-postgres-0` in namespace `devops-helm` using `pg_dump -U devops -d demoapp --format=custom --no-owner`.

Backups are named `demoapp-YYYYMMDDTHHMMSSZ.dump`, with timestamp in **UTC**. The shell script creates a `.partial` file, checks that the result is nonempty and readable with `pg_restore --list`, then renames the completed archive. The automated service runs as root.

| Location | Purpose | Protection |
|---|---|---|
| `/var/backups/cloudforge/postgres/` | Primary local backup | Root-owned directory and `.dump` files; restrictive permissions |
| `/var/backups/cloudforge-export/` | Transfer staging | `root:cloudforge-backup`, directory mode `2750`, exported files mode `640` |
| `D:\CloudForge-Backups\` | Off-VM copy on Windows | Must be access-restricted to authorized Windows account(s) |

This **is not an independent off-site backup**: if the Windows host or its `D:` drive fails, the external copies can also be lost. For stronger protection, add encrypted backups to a separate disk or remote object storage with lifecycle, access controls, and restore tests.

### 3.2 Scheduling

- Ubuntu: `cloudforge-postgres-backup.timer`, `OnCalendar=daily`, at **00:00 UTC**, with `Persistent=true`.
- Windows: Task Scheduler task **CloudForge PostgreSQL Off-VM Backup**, daily at **05:30 local Windows time** (in this environment, 00:30 UTC). The task connects to Ubuntu over SSH on `127.0.0.1:2222` and synchronizes available backups.
- A Windows sync failure must be treated as a **backup protection failure** even if the Linux backup succeeds.
- Jobs depend on the Windows host and `devops-server` being running and reachable; plan a missed-run retry or catch-up procedure.

**Retention status:** Automatic deletion of old archives should remain **disabled** until off-VM copying, hash verification, and retention coordination are validated. A proposed seven-day local retention rule is **not** evidence that safe retention has been deployed. Never delete the only verified copy of a backup.

### 3.3 Verification levels

1. **Backup execution:** systemd service exits successfully and creates a nonempty `.dump`.
2. **Archive structure:** `pg_restore --list` displays expected tables and `TABLE DATA` entries.
3. **Transfer integrity:** SHA-256 of Windows copy matches its source.
4. **Freshness:** Windows sync script checks the UTC timestamp in the backup filename; current threshold is **26 hours**.
5. **Restore:** restore into a **new test database**, inspect tables and verify required records.
6. **Full DR:** rebuild K3s/VM and restore service from independent copies — **not yet validated**.

A checksum confirms transfer fidelity, **not** semantic correctness or recoverability. An empty or inaccessible result should alert an operator even when a scheduled task process returns success. The current sync script skips pre-existing local files without rehashing them; this is an open improvement.

## 4. Routine operator commands

### 4.1 Inspect backup service and timer

```bash
sudo systemctl status cloudforge-postgres-backup.timer --no-pager
systemctl list-timers --all | grep cloudforge-postgres-backup
sudo systemctl show cloudforge-postgres-backup.service -p Result -p ExecMainStatus
sudo journalctl -u cloudforge-postgres-backup.service -n 80 --no-pager
```

A successful `Type=oneshot` service can be `inactive (dead)` after it finishes; inspect its **Result**, exit status and logs. A newly created timer may have an empty `LastTriggerUSec` until its first scheduled activation.

### 4.2 Run a controlled on-demand backup

```bash
sudo systemctl start cloudforge-postgres-backup.service
sudo systemctl show cloudforge-postgres-backup.service -p Result -p ExecMainStatus
sudo ls -lh /var/backups/cloudforge/postgres/
sudo ls -lh /var/backups/cloudforge-export/
```

The backups contain application data. Do not commit or paste their content into Git or chat. Never use `chmod 777` to make them transferable.

### 4.3 Check scheduled Windows copy

In **Windows PowerShell**:

```powershell
Get-ScheduledTaskInfo -TaskName "CloudForge PostgreSQL Off-VM Backup" |
  Select-Object LastRunTime, LastTaskResult, NextRunTime

Get-ChildItem 'D:\CloudForge-Backups' -Filter 'demoapp-*.dump' |
  Sort-Object Name -Descending |
  Select-Object -First 5 Name, Length, LastWriteTime
```

Run the script interactively only as needed (adjust this example if the script has been moved):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$HOME\cloudforge-vagrant\sync-backups.ps1"
```

`LastTaskResult = 0` confirms process exit status, **not** necessarily that a new backup was downloaded. Confirm source freshness, hashes, and subsequent restore capability. The current scheduled task was tested through manual `Start-ScheduledTask`; repeated unattended daily execution is not yet verified.

## 5. Restore drill — non-destructive procedure

**Use this section only for a disposable test database. Never specify the live `demoapp` as the restore target.** The test database is created on the existing PostgreSQL instance, so this drill does not test recovery from total loss of that instance or its storage.

### 5.1 Select and retrieve a verified Windows backup

On Windows, select a known-good `.dump` in `D:\CloudForge-Backups`. Copy it back into Ubuntu (example filename; substitute the actual file):

```powershell
scp -P 2222 `
  'D:\CloudForge-Backups\demoapp-20261017T162854Z.dump' `
  devops@127.0.0.1:/tmp/cloudforge-restore-test.dump

(Get-FileHash 'D:\CloudForge-Backups\demoapp-20261017T162854Z.dump' -Algorithm SHA256).Hash
```

On Ubuntu:

```bash
sha256sum /tmp/cloudforge-restore-test.dump
pg_restore --list /tmp/cloudforge-restore-test.dump | grep -E 'TABLE|TABLE DATA|SEQUENCE'
```

Verify the two SHA-256 values match. For sensitive data, use a secure temporary location and remove the returned dump after testing.

### 5.2 Create a uniquely named disposable database

Choose a new lowercase name (example: `demoapp_restore_drill_20261017`). Check that it does **not** already exist:

```bash
sudo k3s kubectl exec -n devops-helm demo-app-postgres-0 -- \
  psql -U devops -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datname='demoapp_restore_drill_20261017';"
```

**Proceed only if the output is empty.** Then:

```bash
sudo k3s kubectl exec -n devops-helm demo-app-postgres-0 -- \
  createdb -U devops demoapp_restore_drill_20261017
```

### 5.3 Restore into the disposable database

```bash
set -o pipefail
pg_restore --no-owner --no-acl -f - /tmp/cloudforge-restore-test.dump |
  sudo k3s kubectl exec -i -n devops-helm demo-app-postgres-0 -- \
    psql -X -v ON_ERROR_STOP=1 -U devops -d demoapp_restore_drill_20261017
```

Inspect successful `CREATE TABLE`, `COPY`, sequence and constraint statements, and verify the command exits successfully. Do not run this pipeline against an already populated destination without a deliberate clean-up plan.

### 5.4 Validate application data

```bash
sudo k3s kubectl exec -n devops-helm demo-app-postgres-0 -- \
  psql -U devops -d demoapp_restore_drill_20261017 -c '\dt'

sudo k3s kubectl exec -n devops-helm demo-app-postgres-0 -- \
  psql -U devops -d demoapp_restore_drill_20261017 \
  -c 'SELECT COUNT(*) FROM messages;'
```

Also compare schema, representative records, constraints and sequences where applicable. A row count alone is not a full data-integrity check. **Do not delete a test database until its contents and ownership have been positively identified.**

**Observed validation (2026-10-17):** Windows copy returned to Ubuntu with matching SHA-256, `pg_restore --list` found `messages` and sequence objects, and a restore into `demoapp_offvm_restore` successfully created the objects and yielded **one row** in `messages`. This is a *test-database restore*, not full infrastructure recovery.

## 6. Incident response scenarios

### A. One Flask Pod is unavailable

```bash
sudo k3s kubectl get deployment,pods -n devops-helm
sudo k3s kubectl describe deployment demo-app-flask -n devops-helm
sudo k3s kubectl get events -n devops-helm --sort-by=.lastTimestamp
sudo k3s kubectl logs -n devops-helm deployment/demo-app-flask --tail=100
sudo k3s kubectl rollout status deployment/demo-app-flask -n devops-helm --timeout=180s
```

Expect Kubernetes to replace failed Pods where possible. Verify the two desired replicas and application `/health`. Remember a single VM remains a single point of failure.

### B. Bad Flask release / image rollout

Flask is **not managed by the current Helm release**. Examine GitHub Actions, the current Deployment image, and its rollout history:

```bash
sudo k3s kubectl get deployment demo-app-flask -n devops-helm \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
sudo k3s kubectl rollout history deployment/demo-app-flask -n devops-helm
```

Choose a **verified** earlier GHCR image SHA. In a controlled incident response, pause competing CD deployments and apply the known-good image:

```bash
# Replace VERIFIED_SHA with a real known-good image tag before running.
sudo k3s kubectl set image deployment/demo-app-flask \
  flask=ghcr.io/vec1or/demo-app:VERIFIED_SHA -n devops-helm
sudo k3s kubectl rollout status deployment/demo-app-flask -n devops-helm --timeout=180s
```

Validate application and database health, then reconcile the desired version in CI/CD and record the incident. **Do not use `helm rollback` for the Flask image**; Helm manages the six infrastructure resources. A Helm rollback may be appropriate for a verified infrastructure-chart regression only, following review of the proposed changes and database consequences.

### C. PostgreSQL corruption or accidental deletion

1. Stop destructive writes and preserve evidence; identify failure scope and latest verified off-VM archive.
2. Check PostgreSQL Pod/PVC status and service health.
3. Restore into a clean **isolated database/instance first** (Section 5).
4. Validate schema, records and application behavior.
5. Plan production recovery separately: downtime, credentials, transactions since backup, cutover, rollback, and data-loss communication.
6. Never overwrite the active database simply because a dump file exists.

### D. K3s control plane or VM fails

```bash
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 100 --no-pager
free -h
df -h /
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

Investigate before restarting services. If a restart is appropriate, document its impact and verify all workloads. Avoid uninstalling K3s or deleting storage as an initial diagnostic step.

### E. Total Ubuntu VM / virtual-disk loss — **not tested end to end**

1. Confirm availability and integrity of a Windows/off-host backup and required credentials.
2. Provision a replacement Ubuntu VM with the supported Vagrant + Ansible procedure; check K3s version, resources and node readiness.
3. Recreate the required namespaces and Kubernetes Secrets from an approved secret source; **never commit secret values**.
4. Install the **infrastructure-only** Helm Chart, ensuring the Flask Deployment is disabled in chart values. Confirm PostgreSQL storage and resources are healthy.
5. Restore PostgreSQL from verified off-VM backup into a newly provisioned database/volume, using a procedure reviewed for the destination's state.
6. Apply the standalone Flask Deployment manifest and configure the restricted GitHub Actions runner/credentials; verify deployment image and health.
7. Restore monitoring from `monitoring/` using Docker Compose and Grafana provisioning; validate metric scrape, logs and alerts.
8. Perform application smoke tests, compare restored data to the backup baseline and record timestamps to measure **actual** RTO/RPO.

**Missing prerequisites for full loss recovery:** tested management of PostgreSQL Secrets, secure distribution of the backup, independent VM provisioning verification from a clean clone, K3s cluster datastore/configuration backup and restoration when required, and timed drill evidence. A logical SQL dump does **not** restore the whole K3s cluster state.

## 7. Post-recovery acceptance checks

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get deployments,statefulsets,pods,svc,pvc -n devops-helm
sudo k3s kubectl rollout status deployment/demo-app-flask -n devops-helm --timeout=180s
helm status demo-app -n devops-helm
helm get manifest demo-app -n devops-helm | grep '^kind:'
```

Check Flask endpoints using a **temporary** port-forward in one shell:

```bash
sudo k3s kubectl port-forward -n devops-helm svc/demo-app-flask-service 5003:5000
```

Then in another shell:

```bash
curl -i http://127.0.0.1:5003/
curl -i http://127.0.0.1:5003/health
curl -i http://127.0.0.1:5003/messages
curl -i http://127.0.0.1:5003/metrics
```

Stop the port-forward after use. Validate database content and sequence behavior, and confirm that monitoring and the backup schedules recovered:

```bash
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up{job="flask-app"}'
curl -fsS http://127.0.0.1:3100/ready
curl -fsS http://127.0.0.1:9093/-/ready
curl -fsS http://127.0.0.1:3000/api/health
systemctl list-timers --all | grep cloudforge-postgres-backup
```

All success criteria must be **observed**, not assumed from a green Pod status alone.

## 8. Security and operational limitations

- Do not store dumps, `.env`, `*.tfstate`, private keys, kubeconfigs or database credentials in Git.
- Existing backup files may contain sensitive application data. Restrict Linux group membership and Windows folder ACLs.
- The current backup and sync jobs use privileged local access; review least-privilege alternatives before using this design in production.
- Alloy currently reads K3s logs from `/var/log/pods` as root and has read-only access to Docker socket; this is a hardening priority.
- Prometheus currently scrapes Flask by a specific ClusterIP. Replace this with service discovery or a stable endpoint before claiming reusable production networking.
- Alertmanager service readiness does **not** prove notifications are delivered; notification routing and alert drill are open tests.
- Windows task success and freshness verification do not prove archival retention, off-site survivability or restore success for every daily backup.
- The backup script's **local retention deletion should remain disabled** until verified off-VM copy, retention and failure handling are integrated.
- This deployment has one K3s node and local-path storage. There is no demonstrated multi-node failover.

## 9. Recovery evidence and open work

| Capability | Evidence | Status |
|---|---|---|
| Manual custom-format `pg_dump` | Archive created; `pg_restore --list` parsed schema/data | Validated |
| Backup through systemd service | `Result=success`, `ExecMainStatus=0`, exported `.dump` | Validated manually |
| Daily systemd timer | Enabled, active, next trigger shown | Configured; unattended schedule not yet observed |
| SSH/SCP Windows copy | New archive downloaded, SHA-256 verified | Validated manually |
| Windows Task Scheduler | `LastTaskResult=0` after explicit start | Configured; unattended schedule not yet observed |
| Windows freshness check | UTC filename timestamp checked; exit code 0 | Validated manually |
| Restore from Windows copy | New test database `demoapp_offvm_restore`; `messages` count 1 | Validated |
| Deletion-safe multi-location retention | No proven off-VM acknowledgement or retention coordination | **Open** |
| Full VM-loss reconstruction and timed RTO/RPO | Not performed | **Open** |
| Independent off-site copy | Not configured | **Open** |

### Incident / drill record template

```text
Incident or drill ID:
Start time (UTC):
Failure observed:
Impact and affected services:
Latest verified backup timestamp (UTC):
Backup source and checksum:
Actions taken:
Application back online (UTC):
Data baseline / restore checks:
Measured recovery duration:
Estimated data loss window:
Issues / follow-up owner:
```

## 10. Operator recovery checklist

- [ ] Identify failure mode and pause conflicting deployment or backup operations if needed.
- [ ] Confirm current Flask/Helm ownership and last known-good image.
- [ ] Check latest backup timestamp, archive readability, checksums and independent copy availability.
- [ ] Preserve existing data and avoid destructive changes before review.
- [ ] Restore into a disposable test database/instance and verify contents.
- [ ] Restore or reconfigure infrastructure and Secrets from trusted sources if required.
- [ ] Confirm PostgreSQL health, Flask readiness and API functionality.
- [ ] Confirm Prometheus scrape, Loki logs, Grafana and Alertmanager health.
- [ ] Confirm systemd and Windows backup schedules and report missed/failed runs.
- [ ] Document observed RPO/RTO, follow-up fixes and final validation evidence.

---

**Runbook scope:** educational, single-VM environment. **DR validation:** successful off-VM logical database restore, not complete-VM disaster recovery. **RPO/RTO:** targets, not guarantees.
