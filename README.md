# File Conversion Pipeline — Deployment Guide

## Directory Layout

```
.
├── cf-infra-pipeline.yaml      # SAM / CloudFormation template
├── samconfig.toml
├── src/
│   ├── dispatcher.py           # Lambda 1 — receives S3 events, deduplicates
│   └── converter.py            # Lambda 2 — converts files, writes to structured bucket
└── layer/
    ├── requirements.txt        # Python deps for converter
    └── python/                 # Populated by `pip install` (see below)
```

---

## 1. Build the Lambda Layer

The converter needs `pypdf`, `python-docx`, `Pillow`, `pytesseract`, and `pdf2image`.

```bash
pip install -r layer/requirements.txt \
    -t layer/python/ \
    --platform manylinux2014_x86_64 \
    --only-binary=:all:
```

> **Tesseract binary** — pytesseract is a wrapper around the Tesseract OCR *binary*.
> For Lambda you need a compiled Tesseract binary in the layer.
> The easiest approach: use the pre-built Lambda layer from
> https://github.com/shelfio/lambda-tesseract-layer
> and add it to `ConverterFunction.Layers` in the template alongside `ConverterDepsLayer`.

---

## 2. Deploy the Stack

```bash
sam build
sam deploy        # uses samconfig.toml defaults; will prompt on first run
```

On success, the CloudFormation Outputs will print:
- `DispatcherFunctionArn` — copy this, you'll need it in the next step

---

## 3. Wire S3 → Dispatcher (Manual — you own the buckets)

Since the raw S3 bucket is managed outside this stack, you must configure the
event notification manually **after** the stack deploys.

### Console
1. Go to S3 → `liorm-polus-raw-data` → **Properties** → **Event notifications**
2. **Create event notification**
   - Event types: `s3:ObjectCreated:*`
   - Destination: **Lambda function**
   - Lambda function ARN: *(paste the DispatcherFunctionArn from step 2)*

### AWS CLI
```bash
DISPATCHER_ARN=$(aws cloudformation describe-stacks \
  --stack-name file-ingestion-stack \
  --query "Stacks[0].Outputs[?OutputKey=='DispatcherFunctionArn'].OutputValue" \
  --output text)

aws s3api put-bucket-notification-configuration \
  --bucket liorm-polus-raw-data \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"LambdaFunctionArn\": \"$DISPATCHER_ARN\",
      \"Events\": [\"s3:ObjectCreated:*\"]
    }]
  }"
```

---

## 4. Test

Upload any file to the raw bucket:
```bash
aws s3 cp myfile.pdf s3://liorm-polus-raw-data/test/myfile.pdf
```

Then check the manifest table:
```bash
aws dynamodb get-item \
  --table-name liorm-at-polus-file-manifest \
  --key '{"file_id": {"S": "test/myfile.pdf"}}'
```

Expected flow:
```
S3 upload
  → Dispatcher (status: PROCESSING written to DynamoDB)
    → Converter async
      → .txt written to liorm-polus-structured-data/test/myfile.txt
      → DynamoDB status: COMPLETED (+ output_key)
```

---

## DynamoDB Manifest Schema

| Field        | Type   | Notes                                      |
|-------------|--------|--------------------------------------------|
| `file_id`   | String | S3 key (partition key)                     |
| `status`    | String | PROCESSING / COMPLETED / FAILED / UNSUPPORTED |
| `bucket`    | String | Source bucket                              |
| `extension` | String | e.g. `.pdf`                                |
| `size_bytes`| Number | From S3 event                              |
| `output_key`| String | Set on COMPLETED                           |
| `error_msg` | String | Set on FAILED                              |
| `owner`     | String | From OwnerName parameter                   |
| `updated_at`| Number | Unix timestamp                             |

---

## Adding New File Types

1. Add the extension to `SUPPORTED_EXTENSIONS` in `dispatcher.py`
2. Add a `_convert_<type>()` function in `converter.py`
3. Add the routing case in `_convert()` in `converter.py`
4. Add any new pip dependencies to `layer/requirements.txt` and rebuild the layer