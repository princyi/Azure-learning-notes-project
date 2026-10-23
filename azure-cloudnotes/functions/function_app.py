"""Queue-triggered Azure Function: processes a note after the API creates it.

Trigger: Service Bus queue 'note-processing' (identity-based connection 'ServiceBusConnection').
Does: load note from Cosmos DB, make a summary, save it back.
Phase 10: swap the naive summary for Azure OpenAI by setting AOAI_ENDPOINT + AOAI_DEPLOYMENT.
"""
import json
import logging
import os

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()
credential = DefaultAzureCredential()
_container = None


def notes_container():
    global _container
    if _container is None:
        client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=credential)
        _container = client.get_database_client(os.environ["COSMOS_DATABASE"]).get_container_client(
            os.environ["COSMOS_CONTAINER"]
        )
    return _container


def summarise(text: str) -> str:
    endpoint = os.getenv("AOAI_ENDPOINT")
    if not endpoint:
        return (text[:140] + "...") if len(text) > 140 else text  # placeholder summary

    from azure.identity import get_bearer_token_provider
    from openai import AzureOpenAI

    client = AzureOpenAI(
        azure_endpoint=endpoint,
        azure_ad_token_provider=get_bearer_token_provider(
            credential, "https://cognitiveservices.azure.com/.default"
        ),
        api_version="2024-10-21",
    )
    resp = client.chat.completions.create(
        model=os.environ["AOAI_DEPLOYMENT"],
        messages=[
            {"role": "system", "content": "Summarise the note in one sentence."},
            {"role": "user", "content": text},
        ],
    )
    return resp.choices[0].message.content


@app.service_bus_queue_trigger(
    arg_name="msg", queue_name="note-processing", connection="ServiceBusConnection"
)
def process_note(msg: func.ServiceBusMessage):
    payload = json.loads(msg.get_body().decode())
    note_id, user_id = payload["id"], payload["userId"]
    logging.info("Processing note %s for user %s (delivery #%s)", note_id, user_id, msg.delivery_count)

    container = notes_container()
    note = container.read_item(note_id, partition_key=user_id)

    # BREAK IT (Phase 6): uncomment to watch retries then dead-lettering after 5 attempts.
    # raise RuntimeError("simulated failure")

    note["summary"] = summarise(note["body"])
    container.replace_item(note_id, note)
    logging.info("Note %s summarised", note_id)


@app.route(route="ping", auth_level=func.AuthLevel.ANONYMOUS)
def ping(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse("pong")
