"""
converter.py — Converter Lambda

Invoked async by: Dispatcher Lambda
Responsibility:
  1. Fetch the raw file from S3
  2. Route to the correct converter by file extension
  3. Upload the resulting .txt to the structured bucket
  4. Update the DynamoDB manifest (COMPLETED or FAILED)

Supported conversions:
  .pdf   → text via pypdf (text-based PDFs) + pytesseract OCR fallback (scanned)
  .docx  → text via python-docx
  .txt   → passthrough (re-uploaded as-is)
  .jpg / .jpeg / .png → OCR via pytesseract + Pillow
"""

import boto3
import io
import json
import os
import time

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["MANIFEST_TABLE"]
STRUCTURED_BUCKET = os.environ["STRUCTURED_BUCKET"]

table = dynamodb.Table(TABLE_NAME)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def handler(event, context):
    bucket = event["bucket"]
    key = event["key"]
    print(f"[Converter] Starting: s3://{bucket}/{key}")

    try:
        raw_bytes = _fetch_from_s3(bucket, key)
        ext = _extension(key)
        text = _convert(raw_bytes, ext, key)
        output_key = _output_key(key)
        _upload_to_structured(text, output_key)
        _mark_completed(key, output_key)
        print(f"[Converter] Done: s3://{STRUCTURED_BUCKET}/{output_key}")

    except Exception as exc:
        print(f"[Converter] ERROR on {key}: {exc}")
        _mark_failed(key, str(exc))
        raise   # re-raise so Lambda marks the invocation as failed


# ---------------------------------------------------------------------------
# S3 helpers
# ---------------------------------------------------------------------------

def _fetch_from_s3(bucket: str, key: str) -> bytes:
    response = s3_client.get_object(Bucket=bucket, Key=key)
    return response["Body"].read()


def _upload_to_structured(text: str, output_key: str):
    s3_client.put_object(
        Bucket=STRUCTURED_BUCKET,
        Key=output_key,
        Body=text.encode("utf-8"),
        ContentType="text/plain; charset=utf-8",
    )


# ---------------------------------------------------------------------------
# Conversion routing
# ---------------------------------------------------------------------------

def _convert(raw_bytes: bytes, ext: str, original_key: str) -> str:
    """Dispatch to the correct converter and return extracted text."""
    if ext == ".pdf":
        return _convert_pdf(raw_bytes)
    elif ext == ".docx":
        return _convert_docx(raw_bytes)
    elif ext in (".jpg", ".jpeg", ".png"):
        return _convert_image(raw_bytes)
    elif ext == ".txt":
        return _convert_txt(raw_bytes)
    else:
        # Should not reach here — Dispatcher filters unsupported types,
        # but guard defensively.
        raise ValueError(f"Unsupported extension: {ext} for {original_key}")


# ---------------------------------------------------------------------------
# PDF converter
# Strategy: try pypdf text extraction first (fast, lossless for digital PDFs).
# If the extracted text is too short (scanned/image PDF), fall back to OCR.
# ---------------------------------------------------------------------------

def _convert_pdf(raw_bytes: bytes) -> str:
    import pypdf                        # noqa: PLC0415  (lazy import — not in stdlib)

    reader = pypdf.PdfReader(io.BytesIO(raw_bytes))
    pages_text = []

    for page_num, page in enumerate(reader.pages, start=1):
        page_text = page.extract_text() or ""
        if _text_is_usable(page_text):
            pages_text.append(page_text)
        else:
            # Scanned page — render and OCR
            print(f"[Converter][PDF] Page {page_num}: sparse text, falling back to OCR")
            ocr_text = _ocr_pdf_page(page, raw_bytes, page_num)
            pages_text.append(ocr_text)

    return "\n\n".join(pages_text)


def _text_is_usable(text: str, min_chars: int = 50) -> bool:
    """Heuristic: if fewer than min_chars non-whitespace chars, treat as scanned."""
    return len(text.strip()) >= min_chars


def _ocr_pdf_page(page, raw_bytes: bytes, page_num: int) -> str:
    """
    Render a single PDF page to an image and OCR it.
    Requires: pdf2image (wraps poppler) + pytesseract + Tesseract binary.
    On Lambda, Tesseract must be bundled in the layer or installed via a custom runtime.
    """
    try:
        from pdf2image import convert_from_bytes   # noqa: PLC0415
        images = convert_from_bytes(raw_bytes, first_page=page_num, last_page=page_num, dpi=200)
        if not images:
            return ""
        return _ocr_image_obj(images[0])
    except ImportError:
        print("[Converter][PDF] pdf2image not available — OCR skipped for this page")
        return ""


# ---------------------------------------------------------------------------
# DOCX converter
# ---------------------------------------------------------------------------

def _convert_docx(raw_bytes: bytes) -> str:
    from docx import Document   # noqa: PLC0415

    doc = Document(io.BytesIO(raw_bytes))
    paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
    return "\n".join(paragraphs)


# ---------------------------------------------------------------------------
# Image converter (JPG / PNG)
# ---------------------------------------------------------------------------

def _convert_image(raw_bytes: bytes) -> str:
    from PIL import Image   # noqa: PLC0415
    img = Image.open(io.BytesIO(raw_bytes))
    return _ocr_image_obj(img)


def _ocr_image_obj(img) -> str:
    import pytesseract   # noqa: PLC0415
    return pytesseract.image_to_string(img)


# ---------------------------------------------------------------------------
# Plain text — passthrough
# ---------------------------------------------------------------------------

def _convert_txt(raw_bytes: bytes) -> str:
    # Try UTF-8 first, then latin-1 as a safe fallback
    try:
        return raw_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return raw_bytes.decode("latin-1")


# ---------------------------------------------------------------------------
# Output key: strip path prefix, replace extension with .txt
# e.g.  uploads/reports/q3.pdf  →  uploads/reports/q3.txt
# ---------------------------------------------------------------------------

def _output_key(original_key: str) -> str:
    base, _ = os.path.splitext(original_key)
    return base + ".txt"


def _extension(key: str) -> str:
    _, ext = os.path.splitext(key.lower())
    return ext


# ---------------------------------------------------------------------------
# DynamoDB manifest updates
# ---------------------------------------------------------------------------

def _mark_completed(key: str, output_key: str):
    table.update_item(
        Key={"file_id": key},
        UpdateExpression="SET #s = :s, output_key = :ok, updated_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "COMPLETED",
            ":ok": output_key,
            ":ts": int(time.time()),
        },
    )


def _mark_failed(key: str, error: str):
    table.update_item(
        Key={"file_id": key},
        UpdateExpression="SET #s = :s, error_msg = :e, updated_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "FAILED",
            ":e": error[:1000],           # DynamoDB item size limit guard
            ":ts": int(time.time()),
        },
    )
    