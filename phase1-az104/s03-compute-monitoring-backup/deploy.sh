#!/usr/bin/env bash
# S03 – Lab 1 : 2 VMs zonales (zones 1 et 2) derrière un Load Balancer Standard zone-redundant
# Usage : depuis le dossier s03, après cp vars.example.sh vars.sh
set -euo pipefail
source ./vars.sh
TAGS="env=lab week=s03"

# --- 1. Resource group + vérification de la taille dans les zones ---
az group create --name "$RG" --location "$LOC" --tags $TAGS -o none
az vm list-skus --location "$LOC" --size Standard_B1s --zone -o table

# --- 2. Réseau : VNet, subnet, NSG (port 80 depuis Internet), NSG attaché au subnet ---
az network vnet create --name vnet-lab-s03 --resource-group "$RG" --location "$LOC" \
  --address-prefixes 10.30.0.0/16 --subnet-name snet-web --subnet-prefixes 10.30.1.0/24 \
  --tags $TAGS -o none
az network nsg create --name nsg-web --resource-group "$RG" --location "$LOC" --tags $TAGS -o none
az network nsg rule create --nsg-name nsg-web --resource-group "$RG" --name allow-http \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet --destination-port-ranges 80 -o none
az network vnet subnet update --vnet-name vnet-lab-s03 --name snet-web --resource-group "$RG" \
  --network-security-group nsg-web -o none

# --- 3a. Public IP zone-redundant + Load Balancer Standard ---
az network public-ip create --name pip-lb-s03 --resource-group "$RG" --location "$LOC" \
  --sku Standard --allocation-method Static --zone 1 2 3 --tags $TAGS -o none
az network lb create --name lb-web-s03 --resource-group "$RG" --location "$LOC" \
  --sku Standard --public-ip-address pip-lb-s03 \
  --frontend-ip-name fe-web --backend-pool-name bp-web --tags $TAGS -o none

# --- 3b. Health probe, load balancing rule (sans SNAT implicite), outbound rule explicite ---
az network lb probe create --lb-name lb-web-s03 --resource-group "$RG" --name probe-http \
  --protocol Http --port 80 --path / --interval 5 -o none
az network lb rule create --lb-name lb-web-s03 --resource-group "$RG" --name rule-http \
  --protocol Tcp --frontend-port 80 --backend-port 80 \
  --frontend-ip-name fe-web --backend-pool-name bp-web --probe-name probe-http \
  --disable-outbound-snat true -o none
az network lb outbound-rule create --lb-name lb-web-s03 --resource-group "$RG" --name outbound-web \
  --frontend-ip-configs fe-web --address-pool bp-web --protocol All -o none

# --- 4. Une NIC (inscrite dans le backend pool) + une VM par zone, nginx via cloud-init ---
for N in 1 2; do
  az network nic create --name "nic-vm$N" --resource-group "$RG" --location "$LOC" \
    --vnet-name vnet-lab-s03 --subnet snet-web \
    --lb-name lb-web-s03 --lb-address-pools bp-web --tags $TAGS -o none
  az vm create --name "vm$N" --resource-group "$RG" --location "$LOC" \
    --zone "$N" --size Standard_B1s --image Ubuntu2404 \
    --nics "nic-vm$N" --storage-sku StandardSSD_LRS \
    --admin-username azureuser --generate-ssh-keys \
    --custom-data cloud-init.yaml --tags $TAGS -o none
done

az vm list --resource-group "$RG" -d \
  --query "[].{name:name, zone:zones[0], privateIp:privateIps, state:powerState}" -o table
echo "Test : for i in \$(seq 1 30); do curl -s http://<LB_PUBLIC_IP>; done | sort | uniq -c"
