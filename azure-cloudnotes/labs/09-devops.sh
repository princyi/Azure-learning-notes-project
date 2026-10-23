#!/usr/bin/env bash
# PHASE 9: DevOps and IaC
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Bicep workflow: lint > what-if > deploy ---
az bicep install
az bicep build -f ../infra/main.bicep --stdout > /dev/null && echo "Bicep compiles"
az deployment group what-if -g $RG -f ../infra/main.bicep -p ../infra/main.bicepparam
az deployment group create -g $RG -f ../infra/main.bicep -p ../infra/main.bicepparam \
  --query properties.outputs -o jsonc
az deployment group list -g $RG -o table                 # deployment history

# BREAK IT (drift): in the Portal, change the App Service plan tier, then re-run what-if.
# It shows exactly what Bicep would revert.

# Export an existing resource group to Bicep (reverse-engineer a portal build)
az group export -n $RG > exported.json
az bicep decompile --file exported.json

# --- GitHub Actions + Azure with OIDC (no stored secrets) ---
# 1. Create an app registration for the pipeline
APPID=$(az ad app create --display-name gh-cloudnotes-deploy --query appId -o tsv)
az ad sp create --id "$APPID"
SUB=$(az account show --query id -o tsv)
az role assignment create --assignee "$APPID" --role Contributor --scope "/subscriptions/$SUB/resourceGroups/$RG"
# 2. Federated credential: trust tokens from your repo's main branch
GH_REPO="<your-github-user>/<your-repo>"
az ad app federated-credential create --id "$APPID" --parameters "{
  \"name\": \"gh-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GH_REPO}:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
# 3. In GitHub repo > Settings > Secrets and variables > Actions, add (they are IDs, not secrets):
echo "AZURE_CLIENT_ID=$APPID  AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)  AZURE_SUBSCRIPTION_ID=$SUB"

# --- App Configuration + feature flags ---
AC=appcfg-lab-$RANDOM
az appconfig create -g $RG -n $AC -l $LOC --sku Free
az appconfig kv set -n $AC --key CloudNotes:MaxAttachmentMB --value 10 --yes --auth-mode login
az appconfig feature set -n $AC --feature ai-summaries --yes
az appconfig feature enable -n $AC --feature ai-summaries --yes
az appconfig kv list -n $AC -o table --auth-mode login

# --- Azure Developer CLI (azd): one-command environments ---
# azd init -t todo-python-mongo-swa-func   # explore a Microsoft sample, then: azd up / azd down

# --- Terraform (optional, same RG in HCL) ---
# resource "azurerm_resource_group" "rg" { name = "rg-tf" location = "centralindia" }
# terraform init && terraform plan && terraform apply

# --- Azure DevOps (alternative to GitHub) ---
# https://dev.azure.com : create org > project > Repos / Pipelines (azure-pipelines.yml) / Boards / Artifacts
az extension add --name azure-devops
