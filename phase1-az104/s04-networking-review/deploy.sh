#!/usr/bin/env bash
# S04 – Lab 1 : hub-and-spoke avec VNet peering (hub + 2 spokes, 3 VMs sans public IP)
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

# --- 6. Nettoyage (fin de S04) : az group delete -n "$RG" --yes --no-wait ---
