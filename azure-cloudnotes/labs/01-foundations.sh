#!/usr/bin/env bash
# PHASE 1: Foundations. Run command by command, not all at once.
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Who am I, where am I? (tenant > subscription) ---
az account show -o table
az account list -o table
az account list-locations --query "[?metadata.regionType=='Physical'].{name:name, display:displayName}" -o table | head -20

# --- Resource group with tags ---
az group create -n $RG -l $LOC --tags app=cloudnotes env=dev owner="$(az account show --query user.name -o tsv)"
az group show -n $RG -o jsonc

# --- RBAC: who has what access at this scope? ---
RG_ID=$(az group show -n $RG --query id -o tsv)
az role assignment list --scope "$RG_ID" -o table
az role definition list --name "Reader" -o jsonc          # a role is just a JSON of allowed actions
az role definition list --query "[?roleType=='BuiltInRole'] | length(@)"   # how many built-in roles exist?

# --- Azure Policy: only allow certain regions (governance) ---
az policy assignment create \
  --name allowed-locations \
  --display-name "Allowed regions" \
  --scope "$RG_ID" \
  --policy "e56962a6-4747-49cd-b67b-bf8b01975c4c" \
  --params '{"listOfAllowedLocations":{"value":["centralindia","southindia"]}}'
# Test it. This should be DENIED by policy:
#   az storage account create -n stdeny$RANDOM -g $RG -l westus --sku Standard_LRS

# --- Resource lock ---
az lock create --name no-delete --lock-type CanNotDelete --resource-group $RG
# Remember to remove it before cleaning up:
#   az lock delete --name no-delete --resource-group $RG

# --- Budget alert (Cost Management). Replace the email ---
SUB_ID=$(az account show --query id -o tsv)
az consumption budget create \
  --budget-name cloudnotes-monthly \
  --amount 1000 --category cost --time-grain monthly \
  --start-date "$(date +%Y-%m-01)" --end-date "2027-12-31" \
  --resource-group $RG 2>/dev/null || echo "If this fails, create the budget in Portal > Cost Management > Budgets"

# --- Explore ---
az resource list -g $RG -o table
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | head -20
az provider register --namespace Microsoft.App       # needed for Container Apps
az provider register --namespace Microsoft.Insights

# BREAK IT: assign yourself Reader on the RG and try to create a storage account. Read the error.
