#!/usr/bin/env bash
# S04 – Labs 1 à 4 : hub-and-spoke, NSG, UDR via NVA, Bastion avec VNet peering (hub + 2 spokes, 3 VMs sans public IP)
# Usage : depuis le dossier s04, après cp vars.example.sh vars.sh
set -euo pipefail
source ./vars.sh
TAGS="lab=s04"

# --- 1. Resource group + 3 VNets sans chevauchement (10.2.0.0/16 réservé à l'on-premises) ---
az group create -n "$RG" -l "$LOC" --tags $TAGS -o none
az network vnet create -g "$RG" -l "$LOC" -n vnet-hub --address-prefixes 10.0.0.0/16 \
  --subnet-name snet-shared --subnet-prefixes 10.0.1.0/24 -o none
az network vnet create -g "$RG" -l "$LOC" -n vnet-spoke1 --address-prefixes 10.1.0.0/16 \
  --subnet-name snet-app --subnet-prefixes 10.1.1.0/24 -o none
az network vnet create -g "$RG" -l "$LOC" -n vnet-spoke2 --address-prefixes 10.3.0.0/16 \
  --subnet-name snet-data --subnet-prefixes 10.3.1.0/24 -o none

# --- 2. Peerings : un lien par sens (hub-spoke1 puis hub-spoke2). Pas de peering spoke1-spoke2. ---
az network vnet peering create -g "$RG" -n hub-to-spoke1 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke1 --allow-vnet-access -o none
# À ce stade, le lien hub-to-spoke1 est "Initiated" : il attend son jumeau.
az network vnet peering create -g "$RG" -n spoke1-to-hub --vnet-name vnet-spoke1 \
  --remote-vnet vnet-hub --allow-vnet-access -o none
az network vnet peering create -g "$RG" -n hub-to-spoke2 --vnet-name vnet-hub \
  --remote-vnet vnet-spoke2 --allow-vnet-access -o none
az network vnet peering create -g "$RG" -n spoke2-to-hub --vnet-name vnet-spoke2 \
  --remote-vnet vnet-hub --allow-vnet-access -o none
az network vnet peering list -g "$RG" --vnet-name vnet-hub \
  --query "[].{name:name, state:peeringState}" -o table

# --- 3. Une VM par VNet, sans public IP et sans NSG (les NSG arrivent au bloc 2) ---
for spec in "vm-hub vnet-hub snet-shared" \
            "vm-spoke1 vnet-spoke1 snet-app" \
            "vm-spoke2 vnet-spoke2 snet-data"; do
  set -- $spec
  az vm create -g "$RG" -n "$1" --image Ubuntu2204 --size Standard_B1s \
    --vnet-name "$2" --subnet "$3" --public-ip-address "" --nsg "" \
    --admin-username azureuser --generate-ssh-keys --tags $TAGS -o none
done
az vm list -g "$RG" -d --query "[].{name:name, ip:privateIps, state:powerState}" -o table

# --- 4. Tests : hub -> spokes (OK), spoke1 -> spoke2 (échec attendu) ---
az vm run-command invoke -g "$RG" -n vm-hub --command-id RunShellScript \
  --scripts "ping -c 3 -W 2 10.1.1.4; echo ---; ping -c 3 -W 2 10.3.1.4" \
  --query "value[0].message" -o tsv
az vm run-command invoke -g "$RG" -n vm-spoke1 --command-id RunShellScript \
  --scripts "ping -c 3 -W 2 10.3.1.4" --query "value[0].message" -o tsv

# --- 5. Preuve : les routes réellement appliquées à vm-spoke1 ---
az network nic show-effective-route-table -g "$RG" -n vm-spoke1VMNic -o table

# =====================  LAB 2 : NSG sur le subnet de la base  =====================
# --- 7. Mini service sur le port 3306 de vm-spoke2 + état de départ (sans NSG) ---
az vm run-command invoke -g "$RG" -n vm-spoke2 --command-id RunShellScript \
  --scripts "setsid nohup python3 -m http.server 3306 >/dev/null 2>&1 &" -o none
az vm run-command invoke -g "$RG" -n vm-hub --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 22; nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv

# --- 8. NSG et règles (créé mais pas encore associé : il ne filtre rien) ---
az network nsg create -g "$RG" -l "$LOC" -n nsg-data --tags $TAGS -o none
az network nsg rule create -g "$RG" --nsg-name nsg-data -n allow-3306-from-hub \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes 10.0.1.0/24 --destination-port-ranges 3306 -o none
az network nsg rule create -g "$RG" --nsg-name nsg-data -n deny-vnet-inbound \
  --priority 4000 --direction Inbound --access Deny --protocol '*' \
  --source-address-prefixes VirtualNetwork --destination-port-ranges '*' -o none

# --- 9. Association au subnet, puis mêmes tests : 3306 passe, 22 expire ---
az network vnet subnet update -g "$RG" --vnet-name vnet-spoke2 -n snet-data \
  --network-security-group nsg-data -o none
az vm run-command invoke -g "$RG" -n vm-hub --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 22; nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv

# --- 10. Preuve : règles effectives de la NIC de vm-spoke2 ---
az network nic list-effective-nsg -g "$RG" -n vm-spoke2VMNic \
  --query "value[0].effectiveSecurityRules[?direction=='Inbound'].{prio:priority, name:name, access:access, src:sourceAddressPrefix}" -o table

# --- 10b. Lab 2b : ASG entre deux VNets = refusé (AllApplicationSecurityGroupsInSecurityRuleMustBeFromSameVnet) ---
az network asg create -g "$RG" -l "$LOC" -n asg-app -o none
az network asg create -g "$RG" -l "$LOC" -n asg-db -o none
az network nic ip-config update -g "$RG" --nic-name vm-spoke1VMNic -n ipconfigvm-spoke1 \
  --application-security-groups asg-app -o none
az network nic ip-config update -g "$RG" --nic-name vm-spoke2VMNic -n ipconfigvm-spoke2 \
  --application-security-groups asg-db -o none
az network nsg rule create -g "$RG" --nsg-name nsg-data -n test-asg-cross-vnet \
  --priority 200 --direction Inbound --access Allow --protocol Tcp \
  --source-asgs asg-app --destination-asgs asg-db --destination-port-ranges 3306 || echo "Refus attendu"

# =====================  LAB 3 : UDR via une NVA (vm-hub)  =====================
# --- 12. Etat de depart : spoke1 -> spoke2 expire (10.0.0.0/8 -> None) ---
az vm run-command invoke -g "$RG" -n vm-spoke1 --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv

# --- 13. Serveur avec journal sur vm-spoke2 (pour lire l'IP source vue) ---
az vm run-command invoke -g "$RG" -n vm-spoke2 --command-id RunShellScript \
  --scripts "pkill -f 'http.server 3306'; setsid nohup python3 -m http.server 3306 >/tmp/srv.log 2>&1 &" -o none

# --- 14. Deux verrous de l'appliance : Azure (NIC) puis Linux ---
az network nic update -g "$RG" -n vm-hubVMNic --ip-forwarding true -o none
az vm run-command invoke -g "$RG" -n vm-hub --command-id RunShellScript \
  --scripts "sysctl -w net.ipv4.ip_forward=1; echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-forward.conf" -o none

# --- 15. Trafic relaye autorise sur les 4 peerings ---
az network vnet peering update -g "$RG" --vnet-name vnet-hub    -n hub-to-spoke1 --set allowForwardedTraffic=true -o none
az network vnet peering update -g "$RG" --vnet-name vnet-spoke1 -n spoke1-to-hub --set allowForwardedTraffic=true -o none
az network vnet peering update -g "$RG" --vnet-name vnet-hub    -n hub-to-spoke2 --set allowForwardedTraffic=true -o none
az network vnet peering update -g "$RG" --vnet-name vnet-spoke2 -n spoke2-to-hub --set allowForwardedTraffic=true -o none

# --- 16. UDR aller (spoke1) et retour (spoke2) vers la NVA ---
az network route-table create -g "$RG" -n rt-spoke1 -l "$LOC" -o none
az network route-table route create -g "$RG" --route-table-name rt-spoke1 -n to-spoke2 \
  --address-prefix 10.3.0.0/16 --next-hop-type VirtualAppliance --next-hop-ip-address 10.0.1.4 -o none
az network vnet subnet update -g "$RG" --vnet-name vnet-spoke1 -n snet-app --route-table rt-spoke1 -o none
az network route-table create -g "$RG" -n rt-spoke2 -l "$LOC" -o none
az network route-table route create -g "$RG" --route-table-name rt-spoke2 -n to-spoke1 \
  --address-prefix 10.1.0.0/16 --next-hop-type VirtualAppliance --next-hop-ip-address 10.0.1.4 -o none
az network vnet subnet update -g "$RG" --vnet-name vnet-spoke2 -n snet-data --route-table rt-spoke2 -o none
az network nic show-effective-route-table -g "$RG" -n vm-spoke1VMNic -o table | grep -E "User|Source"

# --- 17. Le routage passe mais le NSG jette encore (source 10.1.1.4 non autorisee) : timeout ---
az vm run-command invoke -g "$RG" -n vm-spoke1 --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv

# --- 18. La regle 100 autorise maintenant la vraie source (spoke 1) et non plus le hub ---
az network nsg rule update -g "$RG" --nsg-name nsg-data -n allow-3306-from-hub \
  --source-address-prefixes 10.1.1.0/24 -o none
az vm run-command invoke -g "$RG" -n vm-spoke1 --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv   # attendu : succeeded
az vm run-command invoke -g "$RG" -n vm-hub --command-id RunShellScript \
  --scripts "nc -zv -w 3 10.3.1.4 3306" --query "value[0].message" -o tsv   # attendu : timeout

# --- 19. Preuve : l'IP source vue par vm-spoke2 est celle de vm-spoke1 (pas de NAT) ---
az vm run-command invoke -g "$RG" -n vm-spoke1 --command-id RunShellScript \
  --scripts "curl -s -m 5 -o /dev/null http://10.3.1.4:3306/" -o none
az vm run-command invoke -g "$RG" -n vm-spoke2 --command-id RunShellScript \
  --scripts "cat /tmp/srv.log" --query "value[0].message" -o tsv

# =====================  LAB 4 : Azure Bastion (Basic) dans le hub  =====================
# --- 20. Subnet dedie (nom impose, /26 minimum) et IP publique Standard Static ---
az network vnet subnet create -g "$RG" --vnet-name vnet-hub -n AzureBastionSubnet \
  --address-prefixes 10.0.2.0/26 -o none
az network public-ip create -g "$RG" -n pip-bastion -l "$LOC" --sku Standard --allocation-method Static -o none

# --- 21. Le NSG de la base bloquerait Bastion (source 10.0.2.x dans VirtualNetwork -> regle 4000) : on l'autorise ---
az network nsg rule create -g "$RG" --nsg-name nsg-data -n allow-ssh-from-bastion \
  --priority 300 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes 10.0.2.0/26 --destination-port-ranges 22 -o none

# --- 22. Bastion Basic (facture a l'heure des le deploiement, ~10 min) ---
az vm start -g "$RG" -n vm-spoke1 -o none
az vm start -g "$RG" -n vm-spoke2 -o none
az network bastion create -g "$RG" -n bas-hub -l "$LOC" \
  --vnet-name vnet-hub --public-ip-address pip-bastion --sku Basic
# Connexion : portail > VM > Connect > Bastion > "Private Key from Local File" (utilisateur azureuser)

# --- 23. Nettoyage du lab 4 : Bastion d'abord, puis l'IP publique (facturee tant qu'elle existe) ---
az network bastion delete -g "$RG" -n bas-hub
az network public-ip delete -g "$RG" -n pip-bastion

# --- 11. Nettoyage (fin de S04) : az group delete -n "$RG" --yes --no-wait ---
