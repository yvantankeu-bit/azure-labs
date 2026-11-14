# S04 – Networking & Review (Azure CLI)

Hands-on labs from my 60-week Azure learning plan (architect, DevOps, security track).
Everything is built with **Azure CLI** from WSL (Ubuntu).

> No real environment values are committed. Copy [`vars.example.sh`](./vars.example.sh) to `vars.sh` (git-ignored).

| Lab | Topic | Status |
|---|---|---|
| 1 | Hub-and-spoke with VNet peering, non-transitivity | ✅ Built and tested |
| 2 | NSG rules, priorities, service tags, ASG | ⏳ To do |
| 3 | UDR through a firewall (NVA) | ⏳ To do |
| 4 | Azure Bastion | ⏳ To do |
| 5 | Internal Load Balancer with health probe | ⏳ To do |

---

## Lab 1 – Hub-and-spoke with VNet peering

### Scenario
An application in spoke 1 and a database in spoke 2 live in separate, isolated VNets. Shared services will sit in a hub. Before adding any filtering, I wanted to prove who can talk to whom.

### Architecture

![Lab 1 architecture: vnet-hub 10.0.0.0/16 peered with vnet-spoke1 10.1.0.0/16 and vnet-spoke2 10.3.0.0/16, no spoke-to-spoke peering](images/lab1-architecture.png)

Built with [`deploy.sh`](./deploy.sh).

### Design decisions

**Address spaces that hold over time.** Hub `10.0.0.0/16`, spoke 1 `10.1.0.0/16`, spoke 2 `10.3.0.0/16`. `10.2.0.0/16` is deliberately left unused because it belongs to the on-premises network that a VPN will connect to the hub later. Two spokes with the same range would already be rejected at peering time (address space overlap), because the hub could not tell where to send a packet. Renumbering a subnet that hosts resources later means moving VMs and rewriting NSG, route and DNS references, while picking the range now costs nothing.

**One peering link per direction.** A single link stays `Initiated`. As soon as the second link exists, both become `Connected`. In CLI, forgetting the second command is the classic mistake.

**No spoke-to-spoke peering.** The hub is the single crossing point, so that a firewall can filter and log traffic later. A direct peering would be simpler and faster, but it bypasses filtering and logging, and it does not scale (10 spokes talking to each other would need 45 peerings, each created in both directions).

**No public IP, no NSG on the VMs.** Tests run through `az vm run-command`, which uses the Azure agent and needs no network path to the VM. NSGs are added on purpose in lab 2.

### Results

| Test | Result |
|---|---|
| `vm-hub` → `vm-spoke1` | 0 % packet loss |
| `vm-hub` → `vm-spoke2` | 0 % packet loss |
| `vm-spoke1` → `vm-spoke2` | 100 % packet loss |

### Why spoke 1 cannot reach spoke 2: the routes

Effective routes of `vm-spoke1` (Azure reserved ranges omitted):

```text
Source    State    Address Prefix     Next Hop Type
Default   Active   10.1.0.0/16        VnetLocal
Default   Active   10.0.0.0/16        VNetPeering
Default   Active   0.0.0.0/0          Internet
Default   Active   10.0.0.0/8         None
```

Peering is **not transitive** because a peering only adds a route to the VNet on the other side: spoke 1 learns `10.0.0.0/16` (the hub) and nothing else. There is no `10.3.0.0/16` line. For a packet to `10.3.1.4`, the only matching route is the system route `10.0.0.0/8` with next hop `None`, so Azure silently drops it. When several routes match, the most specific prefix wins: for `10.0.1.4`, `/16` beats `/8`, which is why the hub answers.

The missing line is exactly what a user-defined route (UDR) pointing at the hub will add in lab 3.

### Clean-up
Resources are kept (VMs deallocated) until the end of S04, then removed with `az group delete -n "$RG" --yes --no-wait`.
