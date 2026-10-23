#!/usr/bin/env bash
# PHASE 3: Compute
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Virtual Machine (IaaS) ---
az vm create -g $RG -n vm-lab --image Ubuntu2204 --size Standard_B1s \
  --admin-username azureuser --generate-ssh-keys --public-ip-sku Standard
az vm list-ip-addresses -g $RG -n vm-lab -o table
az vm open-port -g $RG -n vm-lab --port 80
az vm run-command invoke -g $RG -n vm-lab --command-id RunShellScript \
  --scripts "sudo apt-get update -y && sudo apt-get install -y nginx"
az vm deallocate -g $RG -n vm-lab        # stops compute billing. 'stop' alone does NOT.
az vm start -g $RG -n vm-lab
az disk list -g $RG -o table             # managed disks
az vm resize -g $RG -n vm-lab --size Standard_B2s

# --- VM Scale Set (COSTLY while running) ---
az vmss create -g $RG -n vmss-lab --image Ubuntu2204 --vm-sku Standard_B1s \
  --instance-count 2 --admin-username azureuser --generate-ssh-keys --upgrade-policy-mode automatic
az vmss scale -g $RG -n vmss-lab --new-capacity 3
# az group delete the VMSS when done:  az vmss delete -g $RG -n vmss-lab

# --- App Service (PaaS) ---
APP=app-lab-$RANDOM
az appservice plan create -g $RG -n asp-lab --is-linux --sku B1
az webapp create -g $RG -p asp-lab -n $APP --runtime "PYTHON:3.11"
az webapp config appsettings set -g $RG -n $APP --settings FOO=bar
az webapp deployment slot create -g $RG -n $APP --slot staging       # needs Standard+ plan: az appservice plan update --sku S1
az webapp log tail -g $RG -n $APP

# --- Azure Container Registry + build an image in the cloud (no local Docker needed) ---
ACR=acrlab$RANDOM
az acr create -g $RG -n $ACR --sku Basic
az acr build -r $ACR -t cloudnotes-api:v1 ../app/api
az acr repository list -n $ACR -o table

# --- Container Instances (run one container, pay per second) ---
az container create -g $RG -n aci-hello --image mcr.microsoft.com/azuredocs/aci-helloworld \
  --dns-name-label hello-$RANDOM --ports 80 --cpu 1 --memory 1
az container show -g $RG -n aci-hello --query ipAddress.fqdn -o tsv

# --- Container Apps (serverless containers with scale to zero) ---
az extension add --name containerapp --upgrade
az containerapp env create -g $RG -n cae-lab -l $LOC
az containerapp create -g $RG -n ca-hello --environment cae-lab \
  --image mcr.microsoft.com/k8se/quickstart:latest --target-port 80 --ingress external \
  --min-replicas 0 --max-replicas 5
az containerapp show -g $RG -n ca-hello --query properties.configuration.ingress.fqdn -o tsv

# --- Azure Functions (serverless). See ../functions for the real one ---
# func init demo --python && cd demo && func new --template "HTTP trigger" --name hello && func start

# --- AKS (COSTLY: delete right after) ---
az aks create -g $RG -n aks-lab --node-count 1 --node-vm-size Standard_B2s --generate-ssh-keys
az aks get-credentials -g $RG -n aks-lab
kubectl get nodes
kubectl create deployment hello --image=mcr.microsoft.com/azuredocs/aci-helloworld
kubectl expose deployment hello --type=LoadBalancer --port=80
kubectl get svc -w
az aks delete -g $RG -n aks-lab --yes --no-wait

# BREAK IT: az appservice plan update -g $RG -n asp-lab --sku F1   (and stop the app), then call it and check logs.
