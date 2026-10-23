#!/usr/bin/env bash
# PHASE 4: Databases and caching
set -euo pipefail

RG=rg-cloudnotes-dev
LOC=centralindia
PW='Ch@ngeMe-'$RANDOM'xY'     # lab only; use Key Vault or Entra auth in real life

# --- Azure SQL Database (serverless, auto-pauses = cheap) ---
SQLSRV=sql-lab-$RANDOM
az sql server create -g $RG -n $SQLSRV -l $LOC --admin-user sqladmin --admin-password "$PW"
az sql db create -g $RG -s $SQLSRV -n notesdb --edition GeneralPurpose --family Gen5 \
  --capacity 1 --compute-model Serverless --auto-pause-delay 60
MYIP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create -g $RG -s $SQLSRV -n myip --start-ip-address $MYIP --end-ip-address $MYIP
# sqlcmd -S $SQLSRV.database.windows.net -d notesdb -U sqladmin -P "$PW" -Q "CREATE TABLE notes(id INT IDENTITY, body NVARCHAR(MAX)); INSERT notes(body) VALUES('hi'); SELECT * FROM notes;"
az sql db list-editions -l $LOC --service-objective GP_S_Gen5_1 -o table | head

# Backups, point-in-time restore, geo-replication
az sql db show -g $RG -s $SQLSRV -n notesdb --query "{earliestRestore:earliestRestoreDate, zone:zoneRedundant}" -o jsonc

# --- Cosmos DB (the real one is in main.bicep) ---
az cosmosdb list -g $RG -o table
# Look at RU charge for a query. In the Portal Data Explorer > New SQL Query:
#   SELECT * FROM c WHERE c.userId = "u1"           (single partition, cheap)
#   SELECT * FROM c WHERE c.title = "x"             (cross-partition fan-out, expensive)
# BREAK IT: compare "Query Stats" RU for both.

# --- PostgreSQL Flexible Server ---
PG=pg-lab-$RANDOM
az postgres flexible-server create -g $RG -n $PG -l $LOC --tier Burstable --sku-name Standard_B1ms \
  --storage-size 32 --admin-user pgadmin --admin-password "$PW" --public-access $MYIP --yes
# psql "host=$PG.postgres.database.azure.com user=pgadmin dbname=postgres sslmode=require"
az postgres flexible-server stop -g $RG -n $PG      # stop to save money (auto-restarts after 7 days)

# --- Redis (COSTLY ~ $16+/mo for smallest; delete after) ---
REDIS=redis-lab-$RANDOM
az redis create -g $RG -n $REDIS -l $LOC --sku Basic --vm-size c0
az redis show -g $RG -n $REDIS --query "{host:hostName, state:provisioningState}" -o jsonc
# Pattern to practice: cache-aside. Check Redis before Cosmos; on a miss, read Cosmos and SET with a TTL.
# az redis delete -g $RG -n $REDIS --yes

# Cleanup
# az sql server delete -g $RG -n $SQLSRV --yes; az postgres flexible-server delete -g $RG -n $PG --yes
