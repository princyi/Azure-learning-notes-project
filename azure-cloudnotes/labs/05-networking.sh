#!/usr/bin/env bash
# PHASE 5: Networking
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- VNet + subnets ---
az network vnet create -g $RG -n vnet-lab -l $LOC --address-prefix 10.10.0.0/16 \
  --subnet-name snet-web --subnet-prefix 10.10.1.0/24
az network vnet subnet create -g $RG --vnet-name vnet-lab -n snet-data --address-prefix 10.10.2.0/24
az network vnet subnet create -g $RG --vnet-name vnet-lab -n AzureBastionSubnet --address-prefix 10.10.250.0/26

# --- NSG: allow 443 in, deny everything else from internet ---
az network nsg create -g $RG -n nsg-web
az network nsg rule create -g $RG --nsg-name nsg-web -n allow-https --priority 100 \
  --access Allow --direction Inbound --protocol Tcp --destination-port-ranges 443 --source-address-prefixes Internet
az network nsg rule create -g $RG --nsg-name nsg-web -n deny-all-in --priority 4000 \
  --access Deny --direction Inbound --protocol '*' --destination-port-ranges '*' --source-address-prefixes '*'
az network vnet subnet update -g $RG --vnet-name vnet-lab -n snet-web --network-security-group nsg-web
az network nsg rule list -g $RG --nsg-name nsg-web -o table

# --- Private Endpoint: reach a storage account without the public internet ---
SA=stlabpe$RANDOM$RANDOM
az storage account create -n $SA -g $RG -l $LOC --sku Standard_LRS
SA_ID=$(az storage account show -n $SA -g $RG --query id -o tsv)
az network vnet subnet update -g $RG --vnet-name vnet-lab -n snet-data --disable-private-endpoint-network-policies true
az network private-endpoint create -g $RG -n pe-storage --vnet-name vnet-lab --subnet snet-data \
  --private-connection-resource-id "$SA_ID" --group-id blob --connection-name pe-conn
az network private-dns zone create -g $RG -n privatelink.blob.core.windows.net
az network private-dns link vnet create -g $RG -n link-vnet-lab --zone-name privatelink.blob.core.windows.net \
  --virtual-network vnet-lab --registration-enabled false
az network private-endpoint dns-zone-group create -g $RG --endpoint-name pe-storage -n zg \
  --private-dns-zone privatelink.blob.core.windows.net --zone-name blob
az storage account update -n $SA -g $RG --public-network-access Disabled

# --- Azure DNS (public zone; use a domain you own) ---
az network dns zone create -g $RG -n example-cloudnotes.com
az network dns record-set a add-record -g $RG -z example-cloudnotes.com -n www -a 20.1.2.3

# --- Load Balancer (L4) ---
az network public-ip create -g $RG -n pip-lb --sku Standard --allocation-method Static
az network lb create -g $RG -n lb-lab --sku Standard --public-ip-address pip-lb \
  --frontend-ip-name fe --backend-pool-name be
az network lb probe create -g $RG --lb-name lb-lab -n http --protocol tcp --port 80
az network lb rule create -g $RG --lb-name lb-lab -n http-rule --protocol tcp \
  --frontend-port 80 --backend-port 80 --frontend-ip-name fe --backend-pool-name be --probe-name http

# --- VNet peering ---
az network vnet create -g $RG -n vnet-lab2 --address-prefix 10.20.0.0/16
az network vnet peering create -g $RG -n lab-to-lab2 --vnet-name vnet-lab --remote-vnet vnet-lab2 --allow-vnet-access
az network vnet peering create -g $RG -n lab2-to-lab --vnet-name vnet-lab2 --remote-vnet vnet-lab --allow-vnet-access

# --- Front Door (global L7, CDN, WAF) ---
az afd profile create -g $RG --profile-name afd-lab --sku Standard_AzureFrontDoor
az afd endpoint create -g $RG --profile-name afd-lab --endpoint-name cloudnotes --enabled-state Enabled
# then add an origin group + origin pointing at your App Service hostname.

# --- Application Gateway + WAF (COSTLY): do this in the Portal for visual learning, then delete ---
# --- Bastion (COSTLY ~ $140/mo), Azure Firewall (COSTLY ~ $900/mo), VPN Gateway (COSTLY): Portal walk-through only ---

# --- Network Watcher: BREAK IT ---
# Block 443 in the NSG, then:
#   az network watcher test-ip-flow -g $RG --vm vm-lab --direction Inbound --protocol TCP \
#     --local 10.10.1.4:443 --remote 1.2.3.4:50000
# It names the exact rule that denied the packet.

# Cleanup: az group delete -n $RG
