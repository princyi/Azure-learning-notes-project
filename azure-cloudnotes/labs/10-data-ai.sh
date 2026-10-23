#!/usr/bin/env bash
# PHASE 10: Data, analytics and AI
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Azure AI Services (multi-service account: Language, Vision, Speech, Translator...) ---
AI=ailab$RANDOM
az cognitiveservices account create -g $RG -n $AI -l $LOC --kind CognitiveServices --sku S0 --yes
KEY=$(az cognitiveservices account keys list -g $RG -n $AI --query key1 -o tsv)
ENDPOINT=$(az cognitiveservices account show -g $RG -n $AI --query properties.endpoint -o tsv)

# Language: sentiment analysis REST call
curl -s -X POST "${ENDPOINT}language/:analyze-text?api-version=2023-04-01" \
  -H "Ocp-Apim-Subscription-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"kind":"SentimentAnalysis","analysisInput":{"documents":[{"id":"1","language":"en","text":"I love learning Azure!"}]}}'

# --- Azure OpenAI / AI Foundry ---
# Requires access approval in your subscription; check the Portal > Azure AI Foundry.
OAI=oailab$RANDOM
az cognitiveservices account create -g $RG -n $OAI -l eastus --kind OpenAI --sku S0 --yes
# Deploy a model (name/version availability changes; pick from Portal > Model catalog):
#   az cognitiveservices account deployment create -g $RG -n $OAI --deployment-name chat \
#     --model-name gpt-4o-mini --model-version "<version>" --model-format OpenAI --sku-name Standard --sku-capacity 10
# Then call it with Entra auth. See ../functions/function_app.py (summarise()).

# --- Document Intelligence (OCR + structured extraction from PDFs/forms) ---
az cognitiveservices account create -g $RG -n docint$RANDOM -l $LOC --kind FormRecognizer --sku F0 --yes

# --- AI Search: full-text + vector search over notes ---
SEARCH=srch-lab-$RANDOM
az search service create -g $RG -n $SEARCH --sku free -l $LOC
az search admin-key show -g $RG --service-name $SEARCH
# Portal > AI Search > Import data (wizard): connect Cosmos DB "notes" container, build an index,
# then try Search explorer. BREAK IT: compare keyword vs vector/semantic ranking for the same query.

# --- Data Factory: ETL (copy blob to blob on a schedule) ---
az extension add --name datafactory
az datafactory create -g $RG -n adf-lab-$RANDOM -l $LOC
# Build the pipeline in the Studio: Copy activity from Blob 'attachments' to a Data Lake sink.

# --- Stream Analytics: SQL over live streams (Event Hub in, Blob/Power BI out) ---
az extension add --name stream-analytics
az stream-analytics job create -g $RG -n asa-lab -l $LOC --output-error-policy Drop \
  --events-outoforder-policy Adjust --events-outoforder-max-delay 5 --events-late-arrival-max-delay 5 \
  --data-locale en-US --compatibility-level 1.2
# Query example: SELECT System.Timestamp t, COUNT(*) c INTO out FROM telemetry TIMESTAMP BY EventEnqueuedUtcTime GROUP BY TumblingWindow(minute, 1)

# --- Read-only walkthroughs (COSTLY, just click through the Portal / free trials) ---
#  Microsoft Fabric (free trial): https://app.fabric.microsoft.com  - Lakehouse, Data Factory, Power BI in one place
#  Azure Databricks: create workspace > notebook > df = spark.read.json("abfss://...")
#  Azure Machine Learning: create workspace > Designer / Automated ML on a sample dataset
#  Azure Data Explorer (Kusto): free cluster at https://dataexplorer.azure.com
#  Microsoft Purview: data catalog, lineage, classification

# Cleanup: az group delete -n $RG --yes --no-wait
