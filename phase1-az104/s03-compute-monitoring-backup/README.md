# S03 – Compute, Monitoring & Backup (Azure CLI)

Hands-on labs from my 60-week Azure learning plan (architect, DevOps, security track).
Everything is built with **Azure CLI** from WSL (Ubuntu).

> No real environment values are committed. Copy [`vars.example.sh`](./vars.example.sh) to `vars.sh` (git-ignored).

| Lab | Topic | Status |
|---|---|---|
| 1 | Zonal VMs behind a zone-redundant Load Balancer, zone failure test | ✅ Built and tested |
| 2 | VM Scale Set across 3 zones with autoscale | In progress |
| 3 | App Service with a staging slot | To do |
| 4 | Containers: ACR + ACI | To do |
| 5 | Monitoring: Log Analytics, KQL, alerts | To do |
| 6 | Backup and restore of a VM | To do |

---

## Lab 1 – Surviving the loss of an availability zone

### Scenario
A small web application must keep answering if one availability zone of Canada Central fails.

### Architecture

![Lab 1 architecture: zone-redundant public IP and Load Balancer in front of vm1 (zone 1) and vm2 (zone 2)](images/lab1-architecture.png)

<details><summary>Same diagram as Mermaid source</summary>

```mermaid
flowchart TB
    U["User (Internet)"] --> PIP["Public IP pip-lb-s03<br/>Standard, zone-redundant (1, 2, 3)"]
    PIP --> LB["Load Balancer lb-web-s03 (Standard)<br/>HTTP health probe on / every 5 s"]
    subgraph REGION["Region canadacentral"]
        subgraph SNET["Subnet snet-web 10.30.1.0/24 – NSG nsg-web (allow TCP 80 from Internet)"]
            VM1["vm1 – zone 1<br/>Standard_B1s, nginx"]
            VM2["vm2 – zone 2<br/>Standard_B1s, nginx"]
        end
    end
    LB --> VM1
    LB --> VM2
```

</details>

Built with [`deploy.sh`](./deploy.sh). nginx is installed at first boot by [`cloud-init.yaml`](./cloud-init.yaml); each VM serves a page with its hostname and the zone it reads from the Instance Metadata Service (IMDS).

### Design decisions

**One VM per zone, not one "multi-zone" VM.** A zonal VM is pinned to its zone: if the zone fails, the VM fails with it and Azure does not move it. Redundancy comes from several VMs in different zones.

**Load Balancer + health probe.** Users only know one IP. An HTTP probe on `/` every 5 seconds takes an unhealthy VM out of rotation automatically.

**Zone-redundant frontend.** Spreading the VMs is useless if the entry point lives in a single zone: it would become a single point of failure. The public IP is created with `--zone 1 2 3`, which requires the **Standard** SKU (Basic is retired and has no zone support).

**No public IP on the VMs.** The VMs are only reachable through the Load Balancer. For outbound traffic (package installation), the load balancing rule has `--disable-outbound-snat true` and an **explicit outbound rule** lets the backend pool use the Load Balancer's public IP (SNAT). Default outbound access is being retired, so outbound connectivity is planned explicitly.

**NSG on the subnet.** One rule (priority 100) allows TCP 80 from the `Internet` service tag. Health probes are allowed by the default rule `AllowAzureLoadBalancerInBound`; everything else inbound is denied by `DenyAllInBound`.

**Disks.** OS disks are `StandardSSD_LRS`: LRS keeps 3 copies in the **same zone** as the VM, so a zone failure makes the disk unavailable too. This is acceptable here because the web servers are **stateless**; important data would live in a zone-redundant service, with backups.

### Tests and results

| Test | Method | Expected | Result |
|---|---|---|---|
| Size available in zones | `az vm list-skus --zone` | Zones 1, 2, 3, no restriction | ✅ |
| End-to-end through the LB (vm1 only) | `curl` | `Hello from vm1 - zone 1` | ✅ |
| vm2 not yet receiving traffic | Run Command + `DipAvailability` metric | Probe at 0 while cloud-init installs nginx | ✅ 0 then 100 one minute later |
| Distribution across both VMs | 30 × `curl` \| `sort \| uniq -c` | Both VMs answer | ✅ 24 vm1 / 6 vm2 (hash-based, not round-robin) |
| **Zone 1 failure** (vm1 stopped) | `curl` every second during `az vm stop` | Short gap, then vm2 only | ✅ ~10 s without answer, then vm2 only |
| vm1 restarted | Same loop during `az vm start` | Back in rotation only once the probe succeeds | ✅ No failed request on the way back |
| OS disk location | `az disk list` | Same zone as the VM, `StandardSSD_LRS` | ✅ vm1 disk in zone 1, vm2 disk in zone 2 |
| Temporary disk on `Standard_B1s` | Run Command: `lsblk`, `df -h /mnt` | Checked, not assumed | ✅ 4 GB `sdb1` mounted on `/mnt` (OS disk `sda` 30 GB) |

**Failover test** – left: requests every second; vm1 is stopped at 11:50:48, the probe marks it unhealthy and traffic moves to vm2:

![Failover from vm1 (zone 1) to vm2 (zone 2)](images/failover-test.png)

```text
11:50:48 <h1>Hello from vm1 - zone 1</h1>
11:50:49                                   <- vm1 is going down, requests time out (curl -m 2)
11:50:56
11:50:59 <h1>Hello from vm2 - zone 2</h1>  <- probe marked vm1 down, all traffic to vm2
```

### Lessons learned
- **Failover is not instantaneous.** The gap (~10 s here) comes from the probe interval and the number of failed probes before a VM is removed. A shorter interval reduces it, at the cost of more probe traffic.
- **A running VM is not a healthy backend.** `VM running` only means the OS is up; the Load Balancer trusts the **health probe**. During cloud-init, vm2 was running but correctly received no traffic.
- **Troubleshooting a VM without public IP:** `az vm run-command invoke` runs a script through the VM agent (no SSH, no network path needed).
- **Troubleshooting from the Load Balancer side:** the `DipAvailability` metric (*Health Probe Status*) per backend IP shows exactly when each VM was considered healthy.
- **Failover is asymmetric.** Going down, the Load Balancer learns about the failure *after* it happened (lost requests). Coming back, it adds the VM only *after* the probe succeeds (no loss). In production, the probe should hit a dedicated `/health` endpoint that checks the application's real readiness.
- **Load distribution is hash-based** (source IP/port, destination, protocol), so short tests from one client are never perfectly balanced.
- **Heredoc quoting:** `<<'EOF'` keeps `$(hostname)` and `$ZONE` literal in `cloud-init.yaml`, so they are evaluated on the VM, not on my workstation.

### What restarts a VM (and loses the temporary disk)
The key question is: **does the VM have to move to another host?**
- No (e.g. resize to a size available on the same cluster): reboot in place, temporary disk kept.
- Yes (deallocate/start, redeploy, resize to a size not available on the cluster, host failure): reboot **and** temporary disk content lost.
- Attaching a data disk does not restart the VM (managed disks live in Azure Storage, not on the host).
- From the v4 generations on, a size only has a temporary disk if its name contains `d` (e.g. `D4ds_v5`, not `D4s_v5`). Older sizes without that rule may still have one: `Standard_B1s` has a 4 GB temporary disk on `/mnt`, despite having no `d`. **Check, don't assume.**

### Cleanup

```bash
az group delete --name "$RG" --yes
az group exists --name "$RG"   # expected: false
```

---

## Lab 2 – VM Scale Set (Flexible) across 3 zones with autoscale

### Scenario
Same web application, but instances are no longer created one by one: a scale set creates them from one model, spreads them across zones and adjusts their number to the load.

### Architecture

![Lab 2 architecture: zone-redundant Load Balancer in front of a Flexible VMSS spread across zones 1-3, with CPU-based autoscale between 2 and 4 instances](images/lab2-architecture.png)

### Design decisions
- **Flexible orchestration:** instances are standard Azure VMs (manageable individually), recommended by Microsoft for new deployments.
- **One model, one count:** size, image, cloud-init, subnet and backend pool are defined once; the scale set creates NICs, disks and VMs and registers them in the pool.
- **Minimum 2 instances:** with 1 instance in a single zone, a zone failure means a full outage until a new instance is provisioned (minutes). Two instances in different zones keep the ~10 s failover seen in lab 1.
- **Scale-out +1 if CPU > 70 % for 5 min, scale-in −1 if CPU < 30 %:** the gap between thresholds prevents **flapping** (removing an instance raises the CPU of the remaining ones; with 69 %/70 %, 3 × 60 % would become 2 × 90 % and trigger a scale-out again).
- **Cooldown:** after each action, autoscale waits before evaluating again, because a new instance only takes traffic once provisioning, cloud-init and the health probe have succeeded.

*Build, tests and results: in progress.*
