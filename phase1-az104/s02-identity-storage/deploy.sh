#!/usr/bin/env bash
# S02 – Identity, Governance & Storage
# Scénario : une équipe d'auditeurs lit des documents, sans modifier ni récupérer les keys.
# Usage : depuis le dossier s02, dans une subscription sans ressources du lab.
set -euo pipefail
source ./vars.sh

# --- 1. Resource group (Where, conteneur du lab) ---
az group create --name "$RG" --location "$LOC" --tags env=lab week=s02 -o none

# --- 2. What : custom role (lire storage, containers, blobs ; pas de listKeys) ---
# custom-role.json est généré (et ignoré par Git) à partir du template : envsubst remplace $SCOPE
command -v envsubst >/dev/null || { echo "envsubst manquant : sudo apt install gettext-base" >&2; exit 1; }
envsubst '$SCOPE' < custom-role.template.json > custom-role.json
az role definition create --role-definition @custom-role.json -o none

# --- 3. Who : security group + test user ---
GROUP_ID=$(az ad group create --display-name "Auditors-s02" --mail-nickname "auditors-s02" \
  --description "Lab S02: read-only access to audit documents" --query id -o tsv)
USER2_ID=$(az ad user show --id "$USER2_UPN" --query id -o tsv)
az ad group member add --group "$GROUP_ID" --member-id "$USER2_ID"

# --- 4. Storage account (ZRS, sans accès public, TLS 1.2) ---
az storage account create --name "$SA" --resource-group "$RG" --location "$LOC" \
  --sku Standard_ZRS --kind StorageV2 --access-tier Hot \
  --min-tls-version TLS1_2 --allow-blob-public-access false \
  --tags env=lab week=s02 -o none
EOF

chmod +x deploy.sh
ls -l deploy.sh

# --- 5. Role assignment : group Auditors → Lab Blob Reader → storage account ---
SA_ID=$(az storage account show --name "$SA" --resource-group "$RG" --query id -o tsv)

az role assignment create --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Lab Blob Reader (s02)" --scope "$SA_ID" -o none

# --- 6. Container docs (control plane : Owner suffit, pas besoin de data role) ---
az storage container-rm create --name docs --storage-account "$SA" --resource-group "$RG" \
  --public-access off -o none

# --- 7. Soft delete blobs + containers (7 jours) ---
# Ne protège PAS contre la suppression du storage account lui-même (→ lock)
az storage account blob-service-properties update --account-name "$SA" --resource-group "$RG" \
  --enable-delete-retention true --delete-retention-days 7 \
  --enable-container-delete-retention true --container-delete-retention-days 7 -o none

# --- 8. Lifecycle : Hot → Cool (30 j) → Cold (90 j) → suppression (2557 j ≈ 7 ans légaux) ---
# Archive non disponible en ZRS. Design prod : 2e compte GRS pour l'archivage.
az storage account management-policy create --account-name "$SA" --resource-group "$RG" \
  --policy @lifecycle-policy.json -o none

# --- 9. User delegation SAS (exemple, à générer au besoin ; ne jamais la stocker) ---
# EXPIRY=$(date -u -d "+1 hour" '+%Y-%m-%dT%H:%MZ')
# az storage blob generate-sas --account-name "$SA" --container-name docs --name rapport.txt \
#   --permissions r --expiry "$EXPIRY" --auth-mode login --as-user -o tsv
# Nécessite generateUserDelegationKey (inclus dans les Storage Blob Data roles, pas dans Lab Blob Reader)
