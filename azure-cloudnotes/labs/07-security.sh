#!/usr/bin/env bash
# PHASE 7: Security and identity
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Key Vault (RBAC mode) ---
KV=kvlab$RANDOM
az keyvault create -g $RG -n $KV -l $LOC --enable-rbac-authorization true
ME=$(az ad signed-in-user show --query id -o tsv)
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
az role assignment create --assignee "$ME" --role "Key Vault Administrator" --scope "$KV_ID"
sleep 30
az keyvault secret set --vault-name $KV -n db-password --value 'S3cret!'
az keyvault secret show --vault-name $KV -n db-password --query value -o tsv
az keyvault secret set --vault-name $KV -n db-password --value 'N3wer!'          # creates version 2
az keyvault secret list-versions --vault-name $KV -n db-password -o table
az keyvault key create --vault-name $KV -n my-key --kty RSA
az keyvault certificate create --vault-name $KV -n my-cert --policy "$(az keyvault certificate get-default-policy)"

# --- Managed identity: give an App Service access to a secret without any password ---
APP=$(az webapp list -g $RG --query "[0].name" -o tsv)
az webapp identity assign -g $RG -n $APP
PID=$(az webapp identity show -g $RG -n $APP --query principalId -o tsv)
az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KV_ID"
# Reference it in app settings, no code changes needed:
az webapp config appsettings set -g $RG -n $APP \
  --settings "DB_PASSWORD=@Microsoft.KeyVault(VaultName=$KV;SecretName=db-password)"

# BREAK IT: remove the role and reload the app
#   az role assignment delete --assignee "$PID" --role "Key Vault Secrets User" --scope "$KV_ID"
# The setting will show a red Key Vault reference error. That's the 403.

# --- User-assigned managed identity (shared across resources) ---
az identity create -g $RG -n id-shared

# --- Entra ID app registration + service principal (for CI/CD or external apps) ---
az ad app create --display-name cloudnotes-demo
APPID=$(az ad app list --display-name cloudnotes-demo --query "[0].appId" -o tsv)
az ad sp create --id "$APPID"
az ad app credential reset --id "$APPID" --display-name lab --years 1   # client secret, treat like a password
# Prefer workload identity federation (Phase 9) over secrets.

# --- Entra ID basics ---
az ad user list --query "[].{name:displayName, upn:userPrincipalName}" -o table | head
az ad group create --display-name cloudnotes-devs --mail-nickname cloudnotes-devs
# Portal > Entra ID > Security: Conditional Access (require MFA), PIM (just-in-time admin roles) need P1/P2 licences.

# --- Defender for Cloud ---
az security pricing list -o table                      # which plans are on
az security pricing create -n VirtualMachines --tier free     # free tier = recommendations only
# Portal > Defender for Cloud > Recommendations, check "Secure score".

# --- Soft delete / purge protection demo ---
az keyvault secret delete --vault-name $KV -n db-password
az keyvault secret list-deleted --vault-name $KV -o table
az keyvault secret recover --vault-name $KV -n db-password

# Cleanup: az keyvault delete -n $KV && az keyvault purge -n $KV
