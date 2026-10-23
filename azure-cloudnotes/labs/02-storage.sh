#!/usr/bin/env bash
# PHASE 2: Storage
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia
SA=stlab$RANDOM$RANDOM     # must be globally unique, lowercase

az storage account create -n $SA -g $RG -l $LOC --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false

# Use Entra ID (--auth-mode login) rather than account keys. Give yourself the role first:
ME=$(az ad signed-in-user show --query id -o tsv)
SA_ID=$(az storage account show -n $SA -g $RG --query id -o tsv)
az role assignment create --assignee "$ME" --role "Storage Blob Data Contributor" --scope "$SA_ID"
sleep 30   # RBAC takes a moment to propagate

# --- Blob ---
az storage container create --account-name $SA -n demo --auth-mode login
echo "hello azure" > hello.txt
az storage blob upload --account-name $SA -c demo -f hello.txt -n hello.txt --auth-mode login
az storage blob list --account-name $SA -c demo --auth-mode login -o table
az storage blob set-tier --account-name $SA -c demo -n hello.txt --tier Cool --auth-mode login   # access tiers

# --- SAS token (BREAK IT: 1 minute expiry) ---
EXPIRY=$(date -u -d "+1 minute" '+%Y-%m-%dT%H:%MZ')
KEY=$(az storage account keys list -n $SA -g $RG --query '[0].value' -o tsv)
SAS=$(az storage blob generate-sas --account-name $SA --account-key "$KEY" -c demo -n hello.txt \
      --permissions r --expiry "$EXPIRY" --https-only -o tsv)
URL="https://$SA.blob.core.windows.net/demo/hello.txt?$SAS"
curl -s "$URL"; echo        # works
sleep 70
curl -s "$URL"; echo        # AuthenticationFailed. Read the XML error.

# --- Azure Files (SMB share) ---
az storage share-rm create --storage-account $SA -g $RG -n myshare --quota 5
az storage file upload --account-name $SA --share-name myshare --source hello.txt --account-key "$KEY"

# --- Queue Storage ---
az storage queue create --account-name $SA -n tasks --auth-mode login
az storage message put --account-name $SA -q tasks --content "do-the-thing" --auth-mode login
az storage message peek --account-name $SA -q tasks --auth-mode login

# --- Table Storage ---
az storage table create --account-name $SA -n People --auth-mode login
az storage entity insert --account-name $SA -t People --entity PartitionKey=india RowKey=1 Name=Asha --auth-mode login

# --- Redundancy: change LRS -> GRS (see replication options) ---
az storage account update -n $SA -g $RG --sku Standard_GRS
az storage account show -n $SA -g $RG --query "{sku:sku.name, secondary:secondaryLocation}" -o jsonc

# --- Data Lake Gen2 = storage account with hierarchical namespace (set at creation only) ---
az storage account create -n ${SA}dl -g $RG -l $LOC --sku Standard_LRS --kind StorageV2 --hns true

# --- AzCopy (install separately): bulk upload ---
# azcopy login && azcopy copy "./folder" "https://$SA.blob.core.windows.net/demo" --recursive

# Cleanup
# az storage account delete -n $SA -g $RG --yes; az storage account delete -n ${SA}dl -g $RG --yes
