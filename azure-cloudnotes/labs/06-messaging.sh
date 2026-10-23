#!/usr/bin/env bash
# PHASE 6: Messaging and integration
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia

# --- Service Bus: queue + topic with subscriptions ---
SB=sblab$RANDOM
az servicebus namespace create -g $RG -n $SB -l $LOC --sku Standard
az servicebus queue create -g $RG --namespace-name $SB -n orders --max-delivery-count 3
az servicebus topic create -g $RG --namespace-name $SB -n notes-events
az servicebus topic subscription create -g $RG --namespace-name $SB --topic-name notes-events -n audit
az servicebus topic subscription create -g $RG --namespace-name $SB --topic-name notes-events -n search-index
# Queue = one consumer gets each message. Topic = every subscription gets a copy.

# Send/receive from code, using Entra ID auth (see ../app/api/main.py and ../functions)
az servicebus queue show -g $RG --namespace-name $SB -n orders \
  --query "{active:countDetails.activeMessageCount, dead:countDetails.deadLetterMessageCount}" -o jsonc

# BREAK IT: make the Function raise an exception. The message is retried maxDeliveryCount times,
# then moves to the dead-letter queue. In Portal: Service Bus > Queue > Service Bus Explorer > Dead-letter.

# --- Event Grid: react to events (blob created) ---
# The system topic is in main.bicep. Subscribe a webhook or Function:
#   az eventgrid system-topic event-subscription create -g $RG --system-topic-name evgt-cloudnotes-dev-storage \
#     -n on-blob --endpoint-type webhook --endpoint https://<your-endpoint> \
#     --included-event-types Microsoft.Storage.BlobCreated

# --- Event Hubs: high-throughput streaming (think millions of events/sec) ---
EH=ehlab$RANDOM
az eventhubs namespace create -g $RG -n $EH -l $LOC --sku Basic
az eventhubs eventhub create -g $RG --namespace-name $EH -n telemetry --partition-count 2
# Rule of thumb: Service Bus = business messages with guarantees. Event Hubs = telemetry streams.
# Event Grid = discrete notifications ("something happened").

# --- Logic Apps (Consumption). Easiest in Portal designer: ---
#   Trigger "When a new email arrives" -> Action "Create blob" or "Post message in Teams"
az extension add --name logic
# az logic workflow create -g $RG -n la-lab --definition @workflow.json

# --- API Management (Consumption tier = pay per call, ~minutes to create) ---
az apim create -g $RG -n apim-lab-$RANDOM -l $LOC --publisher-email you@example.com \
  --publisher-name "Lab" --sku-name Consumption
# Then in Portal: add the API, apply policies: rate-limit-by-key, validate-jwt, set-header, cache-lookup.

# --- SignalR Service (real-time push to browsers) ---
az signalr create -g $RG -n sigr-lab-$RANDOM --sku Free_F1 --service-mode Default

# Cleanup: az servicebus namespace delete -g $RG -n $SB; az eventhubs namespace delete -g $RG -n $EH
