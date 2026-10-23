""" API: FastAPI app using only managed identity / Entra ID (no keys, no connection strings).

Azure services touched: App Service, Cosmos DB, Blob Storage, Service Bus,
Key Vault (optional), Application Insights.
"""
import json
import os
import uuid
from datetime import datetime, timezone

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.monitor.opentelemetry import configure_azure_monitor
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.storage.blob import BlobServiceClient
from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel

# Application Insights tracing (no-op if the connection string is not set, e.g. local dev)
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor()

# DefaultAzureCredential: managed identity in Azure, `az login` identity on your laptop.
credential = DefaultAzureCredential()

cosmos = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=credential)
notes = cosmos.get_database_client(os.environ["COSMOS_DATABASE"]).get_container_client(
    os.environ["COSMOS_CONTAINER"]
)
blobs = BlobServiceClient(os.environ["STORAGE_ACCOUNT_URL"], credential=credential)
attachments = blobs.get_container_client(os.environ.get("BLOB_CONTAINER", "attachments"))

app = FastAPI(title="CloudNotes API")


class NoteIn(BaseModel):
    userId: str
    title: str
    body: str


def enqueue(note_id: str, user_id: str) -> None:
    """Send a message to Service Bus so the Function processes the note asynchronously."""
    with ServiceBusClient(os.environ["SERVICEBUS_FQDN"], credential) as sb:
        with sb.get_queue_sender(os.environ["SERVICEBUS_QUEUE"]) as sender:
            sender.send_messages(
                ServiceBusMessage(json.dumps({"id": note_id, "userId": user_id}))
            )


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/notes", status_code=201)
def create_note(note: NoteIn):
    doc = {
        "id": str(uuid.uuid4()),
        **note.model_dump(),
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "summary": None,
        "attachments": [],
    }
    notes.create_item(doc)
    enqueue(doc["id"], doc["userId"])
    return doc


@app.get("/notes/{user_id}")
def list_notes(user_id: str):
    # Passing partition_key keeps this a cheap single-partition query (Phase 4 lesson).
    return list(
        notes.query_items(
            "SELECT * FROM c WHERE c.userId = @u ORDER BY c.createdAt DESC",
            parameters=[{"name": "@u", "value": user_id}],
            partition_key=user_id,
        )
    )


@app.get("/notes/{user_id}/{note_id}")
def get_note(user_id: str, note_id: str):
    try:
        return notes.read_item(note_id, partition_key=user_id)
    except Exception:
        raise HTTPException(404, "Note not found")


@app.post("/notes/{user_id}/{note_id}/attachments", status_code=201)
async def upload_attachment(user_id: str, note_id: str, file: UploadFile = File(...)):
    note = get_note(user_id, note_id)
    blob_name = f"{user_id}/{note_id}/{file.filename}"
    attachments.upload_blob(blob_name, await file.read(), overwrite=True)
    note["attachments"].append(blob_name)
    notes.replace_item(note_id, note)
    return {"blob": blob_name}


@app.get("/secret-demo")
def secret_demo():
    """Phase 7 demo: read a secret from Key Vault using managed identity."""
    vault = os.getenv("KEY_VAULT_URL")
    if not vault:
        raise HTTPException(501, "Set KEY_VAULT_URL to try this")
    value = SecretClient(vault, credential).get_secret("demo-secret").value
    return {"length": len(value)}  # never return the secret itself
