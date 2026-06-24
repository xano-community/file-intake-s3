# Enterprise S3 File Intake Workflow (Xano module)

Xano as the **workflow and governance layer** for files stored in **AWS S3**. S3 stores the file bytes; Xano stores the metadata, validates each file, drives an approval **state machine**, logs every event, and exposes the whole thing as a small HTTP surface you can drop into any workspace.

Drop this module into a Xano workspace, point it at your S3 bucket, and you get a complete intake pipeline: register an uploaded object, validate its type and size, route it through review/approval, mark it processed, and read back a full audit trail — all without Xano ever holding the file itself.

## 1. What this template demonstrates

- **Separation of concerns** — S3 is the system of record for **bytes**; Xano is the system of record for **metadata, status, and decisions**. The two are joined by the object's `s3_key`.
- **A real state machine** — every file moves through an explicit set of statuses, and illegal transitions are refused (you can't approve a file that was never sent to review, validate a file twice, or process one that wasn't approved).
- **Validation at the gate** — files are accepted only if their type is one of `pdf`, `csv`, `xlsx`, `json` and they are `≤ 25 MB`; anything else is marked `failed`.
- **Full auditability** — every status change appends a `file_events` row, every review writes a `file_reviews` row, and every API call writes an `api_request_logs` row (on success **and** failure).
- **Genuine S3 awareness** — the canonical S3 object URL is built from your bucket + region, and when AWS credentials are configured the `validate` step additionally confirms the object actually exists in S3 (via Xano's native `cloud.aws.s3.get_file_info`).

This is intake, validation, approval, and auditability only — there is **no** AI extraction/summarization, and **no** Azure Blob / GCS support.

## 2. Required environment variables

Set these in your Xano workspace (Settings → Environment Variables). Every one is read by the module's code.

| Variable | Used for | Required |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | Authenticating the native S3 object-existence check on `validate` | For the S3 existence check |
| `AWS_SECRET_ACCESS_KEY` | Authenticating the native S3 object-existence check on `validate` | For the S3 existence check |
| `AWS_REGION` | Building the canonical S3 URL **and** the S3 existence check | Yes |
| `S3_BUCKET_NAME` | Building the canonical S3 URL **and** the S3 existence check | Yes |
| `API_AUTH_SECRET` | The shared secret every endpoint requires | Yes in production |

**About `API_AUTH_SECRET`.** Every endpoint checks it. When it is **set**, each request must present the same value (in the `X-API-Secret` header or the `api_secret` body/query field) or it is rejected with `403` and logged as `unauthorized`. When it is **unset/empty** (e.g. a fresh, un-provisioned workspace) the check is a deliberate **no-op** so the module still runs out of the box — **you must set it in production.**

**About the AWS keys.** `AWS_REGION` and `S3_BUCKET_NAME` are always used to construct the canonical object URL returned by `register` and `status`. `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are used by the `validate` endpoint to call `cloud.aws.s3.get_file_info` and confirm the object exists in S3. If the two key variables are not configured, the existence check is **skipped** (validation still runs on the declared metadata) — so the module is usable before you wire in credentials, and stricter once you do.

## 3. Required S3 setup

1. **Create (or pick) an S3 bucket** in the region you'll put in `AWS_REGION`, and put its name in `S3_BUCKET_NAME`.
2. **Create an IAM user/role** with read access to that bucket — at minimum `s3:GetObject` and `s3:ListBucket` on `arn:aws:s3:::<bucket>` and `arn:aws:s3:::<bucket>/*` (the existence check uses a HEAD-style metadata read). Put its access key in `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.
3. **Upload the file bytes to S3 yourself** (browser upload, SDK, your own presigned URL, etc.), then call `POST /files/register` with the resulting `s3_key`. **This module does not issue presigned upload URLs** — `register` is the handoff point where S3 (bytes) meets Xano (workflow).
4. The canonical object URL the module returns is the virtual-hosted-style form: `https://<S3_BUCKET_NAME>.s3.<AWS_REGION>.amazonaws.com/<s3_key>`.

## 4. File status lifecycle

```
                ┌───────────► failed           (validation rejects type/size, or S3 object missing)
                │
 registered ──► validated ──► needs_review ──► approved ──► processed
                                   │
                                   └─────────► rejected
```

| Status | Meaning | Set by |
| --- | --- | --- |
| `registered` | Metadata recorded; bytes are in S3 | `POST /files/register` |
| `validated` | Type ∈ {pdf,csv,xlsx,json} and size ≤ 25 MB (and, if creds set, the S3 object exists) | `POST /files/{file_id}/validate` |
| `failed` | Failed validation (bad type, too large, or object not found in S3) | `POST /files/{file_id}/validate` |
| `needs_review` | Awaiting a reviewer decision | `POST /files/{file_id}/send-to-review` |
| `approved` | A reviewer approved it | `POST /files/{file_id}/approve` |
| `rejected` | A reviewer rejected it (with a note) | `POST /files/{file_id}/reject` |
| `processed` | Downstream processing is complete | `POST /files/{file_id}/mark-processed` |

**Transition guards** (enforced; an illegal call returns `400` and is logged):

- `validate` only from `registered`
- `send-to-review` only from `validated`
- `approve` / `reject` only from `needs_review`
- `mark-processed` only from `approved`

Every transition appends a `file_events` row, so a file's history is always reconstructable from the event log.

### Data model

| Table | Purpose |
| --- | --- |
| `files` | One row per file: `s3_key` (unique), `file_name`, `file_type`, `file_size_bytes`, `uploaded_by`, `status`, `created_at`, `updated_at`. |
| `file_events` | Append-only audit trail: `file_id`, `event_type`, `event_payload`, `created_by`, `created_at`. One row per lifecycle action. |
| `file_reviews` | One row per review: `file_id`, `review_status` (`pending`→`approved`/`rejected`), `reviewer_id`, `review_note`, `created_at`. |
| `api_request_logs` | One row per API call: `request_id`, `endpoint`, `requester_id`, `status`, `error_message`, `created_at`. |

## 5. Endpoint reference

All endpoints live in the API group canonical `s3-file-intake` and require the API secret (header `X-API-Secret: <secret>` or an `api_secret` field), enforced when `API_AUTH_SECRET` is set. Every call writes an `api_request_logs` row.

| Method | Path | Body / params | Does |
| --- | --- | --- | --- |
| `POST` | `/files/register` | `s3_key`, `file_name`, `file_type`, `file_size_bytes`, `uploaded_by` | Create a `files` row (`registered`) + `file_registered` event. |
| `POST` | `/files/{file_id}/validate` | — | Validate type + size (and S3 existence if creds set). → `validated` or `failed`, with an event. |
| `POST` | `/files/{file_id}/send-to-review` | — | Only from `validated`. → `needs_review` + a pending `file_reviews` row + an event. |
| `POST` | `/files/{file_id}/approve` | `reviewer_id`, `review_note` | Only from `needs_review`. File → `approved`, review → `approved`, with an event. |
| `POST` | `/files/{file_id}/reject` | `reviewer_id`, `review_note` (non-empty) | Only from `needs_review`. File → `rejected`, review → `rejected`, with an event. |
| `POST` | `/files/{file_id}/mark-processed` | — | Only from `approved`. → `processed`, with an event. |
| `GET` | `/files/{file_id}/status` | — | Return metadata, current status, latest review status, S3 URL, and full event history. |

## 6. Example requests

Base URL: `https://<your-instance>.xano.io/api:s3-file-intake`. Set `X-API-Secret` if you've configured `API_AUTH_SECRET`.

```sh
# 1. Register an object you've already uploaded to S3
curl -X POST "$BASE/files/register" \
  -H "Content-Type: application/json" -H "X-API-Secret: $SECRET" \
  -d '{"s3_key":"incoming/2026/report.pdf","file_name":"report.pdf","file_type":"pdf","file_size_bytes":1048576,"uploaded_by":"alice"}'

# 2. Validate it (id 42 from the register response)
curl -X POST "$BASE/files/42/validate" -H "X-API-Secret: $SECRET"

# 3. Send it to review
curl -X POST "$BASE/files/42/send-to-review" -H "X-API-Secret: $SECRET"

# 4. Approve it
curl -X POST "$BASE/files/42/approve" \
  -H "Content-Type: application/json" -H "X-API-Secret: $SECRET" \
  -d '{"reviewer_id":"bob","review_note":"Looks good."}'

# 5. Mark it processed
curl -X POST "$BASE/files/42/mark-processed" -H "X-API-Secret: $SECRET"

# 6. Read the full status + history
curl "$BASE/files/42/status?api_secret=$SECRET"
```

## 7. Example responses

`POST /files/register` →

```json
{
  "file": {
    "id": 42,
    "s3_key": "incoming/2026/report.pdf",
    "file_name": "report.pdf",
    "file_type": "pdf",
    "file_size_bytes": 1048576,
    "uploaded_by": "alice",
    "status": "registered",
    "created_at": 1782319000000,
    "updated_at": 1782319000000
  },
  "s3_url": "https://your-bucket.s3.us-east-1.amazonaws.com/incoming/2026/report.pdf",
  "status": "registered"
}
```

`POST /files/42/validate` →

```json
{
  "file": { "id": 42, "status": "validated", "file_type": "pdf", "file_size_bytes": 1048576 },
  "status": "validated",
  "valid": true,
  "reason": "",
  "s3_object_checked": false,
  "s3_object_exists": false
}
```

`GET /files/42/status` →

```json
{
  "file": { "id": 42, "status": "processed", "s3_key": "incoming/2026/report.pdf" },
  "status": "processed",
  "review_status": "approved",
  "latest_review": { "id": 7, "review_status": "approved", "reviewer_id": "bob", "review_note": "Looks good." },
  "s3_url": "https://your-bucket.s3.us-east-1.amazonaws.com/incoming/2026/report.pdf",
  "events": [
    { "event_type": "file_registered" },
    { "event_type": "file_validated" },
    { "event_type": "file_sent_to_review" },
    { "event_type": "file_approved" },
    { "event_type": "file_processed" }
  ]
}
```

An illegal transition (e.g. approving a file that isn't in review) returns `400`:

```json
{ "code": "ERROR_CODE_INPUT_ERROR", "message": "Action 'approve' requires status 'needs_review', but the file is 'validated'." }
```

## 8. How Xano centralizes file workflow logic while S3 stores files

The division of labor is the whole point:

- **S3 holds the bytes.** Your client uploads directly to the bucket; the object lives there, addressed by `s3_key`. Xano never streams or stores the file content, so there's no duplication, no size ceiling imposed by the app tier, and no egress through Xano.
- **Xano holds the workflow.** Around each object, Xano keeps the metadata (`files`), the decision record (`file_reviews`), the audit trail (`file_events`), and the traffic log (`api_request_logs`). The **state machine** lives here too — the legal-transition rules are enforced in one place, so "what can happen to a file next" is a single, testable definition rather than logic scattered across clients.
- **The `s3_key` is the join.** Register binds a Xano `files` row to an S3 object; from then on the canonical URL (`https://<bucket>.s3.<region>.amazonaws.com/<s3_key>`) is reconstructable on demand, and `validate` can ask S3 (with your credentials) whether the object is really there.

The result: S3 does what object storage is good at (durable, cheap, scalable bytes), and Xano does what a backend is good at (validation, status, approvals, history, access control) — joined by a key, with every step observable through the event and request logs.

## Install

### Option A — Ask Claude Code
With the [Xano MCP](https://github.com/xano-labs/mcp-server) enabled, paste:

> Install the module at https://github.com/xano-community/s3-file-intake-workflow into my Xano workspace.

### Option B — Xano CLI
```sh
git clone https://github.com/xano-community/s3-file-intake-workflow.git
cd s3-file-intake-workflow
xano workspace push backend -w <your-workspace-id>
```

## License

MIT — see [LICENSE](./LICENSE).
