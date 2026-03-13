"""
dispatcher.py — Dispatcher Lambda

Triggered by: S3 ObjectCreated event (configured manually on the raw bucket)
Responsibility:
  1. Deduplicate via DynamoDB manifest
  2. Register the file as PROCESSING
  3. Async-invoke the Converter Lambda
"""

import boto3
import json
import os
import time

dynamodb = boto3.resource("dynamodb")
lambda_client = boto3.client("lambda")

TABLE_NAME = os.environ["MANIFEST_TABLE"]
CONVERTER_FUNCTION = os.environ["CONVERTER_FUNCTION"]
OWNER_NAME = os.environ.get("OWNER_NAME", "unknown")

table = dynamodb.Table(TABLE_NAME)

# Extensions we know how to convert — anything else is flagged, not failed
SUPPORTED_EXTENSIONS = {".pdf", ".docx", ".txt", ".jpg", ".jpeg", ".png"}


def handler(event, context):
    """Entry point. Processes one or more S3 records per invocation."""
    results = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        size = record["s3"]["object"].get("size", 0)

        print(f"[Dispatcher] Received: s3://{bucket}/{key}  ({size} bytes)")
        result = _dispatch(bucket, key, size)
        results.append(result)

    return {"dispatched": results}


def _dispatch(bucket: str, key: str, size: int) -> dict:
    ext = _extension(key)

    # --- 1. Deduplication check ---
    existing = table.get_item(Key={"file_id": key}).get("Item")
    if existing:
        status = existing.get("status")
        if status == "COMPLETED":
            print(f"[Dispatcher] SKIP — already completed: {key}")
            return {"key": key, "action": "skipped", "reason": "already_completed"}
        if status == "PROCESSING":
            print(f"[Dispatcher] SKIP — currently processing: {key}")
            return {"key": key, "action": "skipped", "reason": "already_processing"}

    # --- 2. Unsupported extension — record but don't invoke converter ---
    if ext not in SUPPORTED_EXTENSIONS:
        print(f"[Dispatcher] UNSUPPORTED extension '{ext}' for {key}")
        table.put_item(Item={
            "file_id": key,
            "status": "UNSUPPORTED",
            "bucket": bucket,
            "extension": ext,
            "owner": OWNER_NAME,
            "updated_at": int(time.time()),
        })
        return {"key": key, "action": "skipped", "reason": "unsupported_extension"}

    # --- 3. Register as PROCESSING ---
    table.put_item(Item={
        "file_id": key,
        "status": "PROCESSING",
        "bucket": bucket,
        "extension": ext,
        "size_bytes": size,
        "owner": OWNER_NAME,
        "updated_at": int(time.time()),
    })

    # --- 4. Async-invoke Converter ---
    payload = {"bucket": bucket, "key": key}
    lambda_client.invoke(
        FunctionName=CONVERTER_FUNCTION,
        InvocationType="Event",      # async — fire and forget
        Payload=json.dumps(payload),
    )
    print(f"[Dispatcher] Invoked converter for {key}")
    return {"key": key, "action": "dispatched"}


def _extension(key: str) -> str:
    """Returns lowercase extension including the dot, e.g. '.pdf'"""
    _, ext = os.path.splitext(key.lower())
    return ext
