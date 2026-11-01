# Copier ce fichier en vars.sh (ignoré par Git) puis remplacer les valeurs <...>
export LOC="canadacentral"
export RG="rg-lab-s02-identity-storage"
export SUB=$(az account show --query id -o tsv)
export SCOPE="/subscriptions/$SUB/resourceGroups/$RG"
export GROUP_ID="<group-object-id>"
export USER2_UPN="<user2-upn>"
export USER2_ID="<user2-object-id>"
export SA="<storage-account-name>"
