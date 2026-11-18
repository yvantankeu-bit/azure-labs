# S04 – Networking & Review (Azure CLI)

Hands-on labs from my 60-week Azure learning plan (architect, DevOps, security track).
Everything is built with **Azure CLI** from WSL (Ubuntu).

> No real environment values are committed. Copy [`vars.example.sh`](./vars.example.sh) to `vars.sh` (git-ignored).

| Lab | Topic | Status |
|---|---|---|
| 1 | Hub-and-spoke with VNet peering, non-transitivity | ✅ Built and tested |
| 2 | NSG on the database subnet: rules, priorities, service tags | ✅ Built and tested |
| 3 | UDR through a firewall (NVA) | ✅ Built and tested |
| 4 | Azure Bastion (Basic), created then deleted | ✅ Built and tested |
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

---

## Lab 2 – Restricting access to the database subnet with an NSG

### Scenario
Only the application may reach the database port. By default, everything in a VNet, including peered VNets, can reach everything else, so the hub could open an SSH session on the database VM.

### Architecture

![Lab 2 architecture: nsg-data associated with snet-data in vnet-spoke2, allowing TCP 3306 from the hub subnet and denying other VirtualNetwork traffic](images/lab2-architecture.png)

Built with the lab 2 section of [`deploy.sh`](./deploy.sh). Spoke 1 has no route to spoke 2 yet (UDR in lab 3), so `vm-hub` plays the application: rule 100 uses the hub subnet `10.0.1.0/24` and will point to the real application subnet `10.1.1.0/24` once lab 3 is done.

### Design decisions

**Rules, in order.** Priority 100 allows TCP 3306 from the application subnet. Priority 4000 denies all traffic from the `VirtualNetwork` service tag. The `Allow` has the smaller number, so it is read first; a `Deny` with a smaller number would hide it.

**Why the explicit Deny is needed.** The default rule `AllowVNetInBound` (65000) allows the `VirtualNetwork` tag, which includes the VNet itself, **peered VNets** and on-premises networks connected through a gateway. Without rule 4000, everything in the hub, and later on-premises, would reach the database.

**Associated with the subnet, not the NIC.** For inbound traffic Azure reads the subnet NSG first, then the NIC NSG, and both must allow. Microsoft recommends one level only, to avoid conflicting rules that are hard to troubleshoot. An NSG that is not associated filters nothing.

**Source by address range, not by ASG.** An application security group can only contain NICs from one VNet, and a rule with an ASG as source and another as destination requires both in the same VNet. The application (spoke 1) and the database (spoke 2) are in different VNets, so the source is a CIDR range.

### Results (from `vm-hub` to `vm-spoke2`)

| State | TCP 22 | TCP 3306 |
|---|---|---|
| No NSG | succeeded | succeeded |
| `nsg-data` created, not associated | succeeded | succeeded |
| `nsg-data` associated with `snet-data` | timed out | succeeded |

A timeout means the packet was dropped on the way (NSG or missing route). `Connection refused` would mean it reached the VM and nothing listens on that port.

Effective rules of the database NIC, in reading order:

```text
Prio    Name                          Access   Src
100     allow-3306-from-hub           Allow    10.0.1.0/24
4000    deny-vnet-inbound             Deny     VirtualNetwork
65000   AllowVnetInBound              Allow    VirtualNetwork
65001   AllowAzureLoadBalancerInBound Allow    AzureLoadBalancer
65500   DenyAllInBound                Deny     0.0.0.0/0
```

Traffic from the hub on port 22 stops at rule 4000; rule 65000 is never read for it.

### Lab 2b – Proving the ASG constraint

Two application security groups were created, `asg-app` (NIC of `vm-spoke1`) and `asg-db` (NIC of `vm-spoke2`), and a rule using them as source and destination was attempted in `nsg-data`. Azure refused it with the error code `AllApplicationSecurityGroupsInSecurityRuleMustBeFromSameVnet`: all ASGs of a security rule must belong to the same virtual network. Between spokes, the source is therefore designated by address range (`10.1.1.0/24`). ASGs remain the right tool for several tiers inside one VNet, where rules can name roles instead of IP addresses.

---

## Lab 3 – UDR through a network virtual appliance (NVA)

### Scenario
Spoke 1 (application) must reach the database in spoke 2, but the two spokes are not peered and peering is not transitive. Instead of peering them, all spoke-to-spoke traffic goes through an appliance in the hub, which is where a firewall would sit. To avoid the cost of Azure Firewall, `vm-hub` plays the NVA as a plain Linux router.

### Architecture

![Lab 3 architecture: user-defined routes in both spokes send spoke-to-spoke traffic to the NVA 10.0.1.4 in the hub; nsg-data now allows the spoke 1 subnet](images/lab3-architecture.png)

Built with the lab 3 section of [`deploy.sh`](./deploy.sh).

### Design decisions

**Routing decides where the packet goes, the NSG decides if it may enter.** Without a route, spoke 1 sends `10.3.0.0/16` traffic to the system route `10.0.0.0/8 → None` and the packet is dropped before anything else is evaluated.

**User-defined routes, in both directions.** `rt-spoke1` sends `10.3.0.0/16` to the appliance `10.0.1.4` (next hop type `VirtualAppliance`). The same logic applies to the return path: `rt-spoke2` sends `10.1.0.0/16` to the appliance, otherwise the reply would not follow the same path. A `/16` route beats the system `/8` by longest prefix match.

**Two locks on the appliance.** Relaying packets that are not addressed to it needs *IP forwarding* enabled on the NIC in Azure **and** `net.ipv4.ip_forward=1` in Linux (persisted in `/etc/sysctl.d/`). Either one missing and the packets die at the appliance.

**Forwarded traffic allowed on the four peering links.** *Allow forwarded traffic* is off by default; it lets a peered VNet accept packets whose source is not in the peered VNet itself.

**The NSG sees the real source.** A plain Linux router does not translate addresses, so the database NSG sees `10.1.1.4`, not the appliance. Rule 100 therefore had to change from the hub subnet to the application subnet `10.1.1.0/24`. A firewall that does NAT would show its own address instead.

**The appliance sits in its own subnet** (`snet-shared`), different from the subnets it routes for, to avoid routing loops.

### Results (TCP 3306 to `vm-spoke2`)

| Step | From | Result | Layer that decided |
|---|---|---|---|
| Baseline, no UDR | `vm-spoke1` | timed out | Routing (`10.0.0.0/8 → None`) |
| Forwarding on, peerings set, UDR in place, rule 100 still on the hub subnet | `vm-spoke1` | timed out | NSG (rule 4000, source `10.1.1.4`) |
| Rule 100 source changed to `10.1.1.0/24` | `vm-spoke1` | succeeded | NSG (rule 100) |
| Same rule | `vm-hub` | timed out | NSG (rule 4000, source `10.0.1.4`) |

Two timeouts, two different causes: the symptom alone does not tell which layer dropped the packet.

Effective route of `vm-spoke1`, the user-defined route taking precedence over the system `/8`:

```text
Source   State   Address Prefix   Next Hop Type     Next Hop IP
User     Active  10.3.0.0/16      VirtualAppliance  10.0.1.4
```

Proof that no NAT happens: the access log of the test server on `vm-spoke2` shows the application's own address as the client.

```text
10.1.1.4 - - [..] "GET / HTTP/1.1" 200 -
```

### Clean-up
VMs are deallocated between sessions (VNets, peerings and route tables are free). The whole resource group is deleted at the end of S04.

---

## Lab 4 – Azure Bastion

### Scenario
The VMs have no public IP, so nothing reaches them from the Internet. Bastion gives browser-based SSH over HTTPS, and reaches the VMs through their private IPs. It is billed per hour from deployment, so it was created, tested and deleted in the same session.

### Design decisions

**SKU Basic, not Developer.** Developer is free but uses shared infrastructure, connects to one VM at a time and **does not support virtual network peering**. Bastion sits in the hub and the targets are in the spokes, so Developer cannot work here. Basic reaches VMs in peered VNets. What Basic lacks (custom port, shareable link, file transfer, native client through `az`) is not needed for this lab.

**Dedicated subnet.** It must be named exactly `AzureBastionSubnet`, be /26 or larger, and contain no other resource. `snet-shared` could not be reused: it holds the NVA, and renaming it would break the lab 3 routing. The new subnet is `10.0.2.0/26`, with a Standard, Static public IP.

**The database NSG had to be opened for Bastion.** The Bastion source (`10.0.2.0/26`) belongs to the `VirtualNetwork` tag through the peering, so `deny-vnet-inbound` (4000) would block SSH to the database VM. Rule 300 allows TCP 22 from `10.0.2.0/26` only, and sits between rule 100 and the Deny so it is read first. `vm-spoke1` has no NSG, so nothing filters it.

**Key authentication.** The VMs were created with SSH keys and no password, so the connection uses *Private Key from Local File* with the admin user.

### Results

| Target | Routing | NSG | Bastion session |
|---|---|---|---|
| `vm-spoke1` | OK (peering route to the hub range) | None | Connected |
| `vm-spoke2` | OK | Rule 300 allows, before Deny 4000 | Connected |

### Clean-up
Bastion and its public IP were deleted right after the test (the public IP is billed as long as it exists). The subnet and rule 300 are free and kept.
