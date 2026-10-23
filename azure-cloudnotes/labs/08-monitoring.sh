#!/usr/bin/env bash
# PHASE 8: Monitoring and operations
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia
LAW=$(az monitor log-analytics workspace list -g $RG --query "[0].name" -o tsv)
LAW_ID=$(az monitor log-analytics workspace show -g $RG -n $LAW --query customerId -o tsv)
APPI=$(az monitor app-insights component show -g $RG --query "[0].name" -o tsv 2>/dev/null || true)

# --- Metrics ---
APP_ID=$(az webapp list -g $RG --query "[0].id" -o tsv)
az monitor metrics list-definitions --resource "$APP_ID" -o table | head -20
az monitor metrics list --resource "$APP_ID" --metric Http5xx --interval PT1M -o table

# --- Action group (who gets notified) + metric alert ---
az monitor action-group create -g $RG -n ag-email --short-name cnotes \
  --action email me you@example.com
az monitor metrics alert create -g $RG -n alert-5xx --scopes "$APP_ID" \
  --condition "total Http5xx > 5" --window-size 5m --evaluation-frequency 1m \
  --action ag-email --description "API returning 5xx errors"

# BREAK IT: hit a bad URL 20 times and wait for the email.
#   for i in $(seq 20); do curl -s -o /dev/null https://<app>.azurewebsites.net/does-not-exist; done

# --- KQL queries (run in Portal > Log Analytics > Logs, or via CLI) ---
az monitor log-analytics query -w "$LAW_ID" --analytics-query "AzureActivity | take 10" -o table

cat <<'KQL'
-- 1. Who did what in my subscription (last 24h)?
AzureActivity | where TimeGenerated > ago(24h) | summarize count() by Caller, OperationNameValue | top 20 by count_ s

-- 2. Failed requests by route (App Insights)
requests | where success == false | summarize failures = count() by name, resultCode | order by failures desc

-- 3. Slowest requests, p95 per operation
requests | summarize p95 = percentile(duration, 95), n = count() by name | order by p95 desc

-- 4. Exceptions, grouped
exceptions | summarize count() by type, outerMessage | order by count_ desc

-- 5. Request volume over time
requests | summarize count() by bin(timestamp, 5m) | render timechart

-- 6. Dependency calls that fail (Cosmos, Service Bus, Blob)
dependencies | where success == false | summarize count() by target, type, resultCode

-- 7. End-to-end trace for one request
union requests, dependencies, traces, exceptions | where operation_Id == "<paste id>" | order by timestamp asc

-- 8. Service Bus dead-letter spikes
AzureMetrics | where ResourceProvider == "MICROSOFT.SERVICEBUS" and MetricName == "DeadletteredMessages" | summarize max(Maximum) by bin(TimeGenerated, 5m)

-- 9. Function execution failures
traces | where cloud_RoleName startswith "func-" and severityLevel >= 3 | project timestamp, message

-- 10. Which resources cost log ingestion the most?
Usage | where TimeGenerated > ago(7d) | summarize GB = sum(Quantity)/1000 by DataType | order by GB desc
KQL

# --- Diagnostic settings: send any resource's logs to Log Analytics ---
KV=$(az keyvault list -g $RG --query "[0].id" -o tsv)
az monitor diagnostic-settings create --name to-law --resource "$KV" \
  --workspace "$LAW" --logs '[{"categoryGroup":"audit","enabled":true}]'

# --- Backup (Recovery Services vault + VM backup) ---
az backup vault create -g $RG -n rsv-lab -l $LOC
az backup protection enable-for-vm -g $RG --vault-name rsv-lab --vm vm-lab --policy-name DefaultPolicy
az backup protection backup-now -g $RG --vault-name rsv-lab --container-name vm-lab --item-name vm-lab --retain-until 01-01-2027

# --- Service / Resource Health (Portal): Monitor > Service Health ---
az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2022-10-01" --query "value[].{res:name,state:properties.availabilityState}" -o table
