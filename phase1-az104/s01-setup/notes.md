# S01 : Mise en place

**Phase 1 : Pratique AZ-104** · Semaine 1 · Octobre 2026

## Objectif
Préparer l'environnement de travail : Subscription, contrôle des coûts, outils locaux, Cloud Shell et dépôt GitHub.

## Ce qui a été fait
- [x] Budget avec alertes Actual (50 / 75 / 100 %) et Forecasted (100 %)
- [x] Azure CLI, Git et VS Code installés (Windows + WSL Ubuntu)
- [x] Compte break-glass créé (Owner + Global Administrator)
- [x] Cloud Shell ouvert
- [x] Clé SSH ajoutée à GitHub
- [x] Repo `azure-labs` créé

## Leçons apprises
- Un Budget **prévient**, il ne **bloque** rien. L'alerte Forecasted prévient avant le dépassement.
- Dans WSL, installer la CLI native (`/usr/bin/az`). Le `az` Windows ajoute un `\r` invisible qui casse les scripts.
- Deux couches de rôles : **Azure RBAC** (ressources) et **Entra ID roles** (annuaire).
- Un **break-glass account** permet de reprendre la main si le compte principal est bloqué (MFA perdu).

## Commandes utiles

```bash
az account show --query "{name:name, user:user.name}" --output table
az group list --output table
az consumption budget list --output table
```

## Règles
1. Supprimer les ressources après chaque lab.
2. Jamais de secret, d'ID ou de `terraform.tfstate` dans le repo.