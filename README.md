# Enterprise S3 File Intake Workflow

Govern files stored in AWS S3 without Xano ever holding the bytes — register uploaded objects, validate type and size, route them through an approval state machine, and keep a full audit trail, all joined to S3 by object key.

S3 is the system of record for the **bytes**; Xano is the system of record for the **metadata, status, and decisions**. Drop this into a Xano workspace, point it at your bucket, and you get a complete intake pipeline — register → validate → review → approve → process — with every step guarded and logged.

## Why this exists

Files arrive in a bucket and then what? Someone eyeballs them, moves the good ones somewhere, and the record of "who approved this, when, and why" lives in memory or a thread. There's no gate that stops an unvalidated or unapproved file from moving downstream, and no reconstructable history when finance or audit asks.

This template makes the intake a governed workflow instead of a convention. Every file moves through an explicit state machine — `registered → validated → needs_review → approved → processed` (with `failed` and `rejected` branches) — and illegal transitions are refused server-side, not left to the UI. Validation runs at the gate (allowed type, size ceiling, and an optional real S3 object-existence check). Every transition appends an immutable event, every review is recorded, and every API call is logged on success and failure. Xano owns the workflow and the audit; S3 keeps holding the bytes.

## Repo layout

## How it works

A file is a row in `files` carrying a `status` and joined to its S3 object by a unique `s3_key`. The lifecycle is a guarded state machine — the transition guard (`s3_file_intake_check_transition`) is a pure function, so the rules hold no matter which endpoint is called:

```
                ┌──────────────► failed        (bad type/size, or S3 object missing)
                │
 registered ──► validated ──► needs_review ──► approved ──► processed
                                    │
                                    └────────► rejected
```

- **register** records the metadata and creates the `files` row (`registered`).
- **validate** (only from `registered`) checks the type is one of `pdf | csv | xlsx | json` and size ≤ 25 MB; if AWS credentials are set it additionally confirms the object exists in S3 via Xano's native `cloud.aws.s3.get_file_info`. Passes → `validated`, fails → `failed`.
- **send-to-review** (only from `validated`) opens a pending review → `needs_review`.
- **approve / reject** (only from `needs_review`) record a reviewer decision.
- **mark-processed** (only from `approved`) closes the loop → `processed`.

Every transition appends a `file_events` row, so a file's history is always reconstructable from the log; every request writes an `api_request_logs` row. There is deliberately **no** AI extraction and **no** Azure/GCS support — this is intake, validation, approval, and auditability.

## Quick start

1. **Push the backend** to a Xano workspace (the CLI/agent flow below does this).
2. **Call the flow** — `POST /files/register` → `POST /files/{file_id}/validate` → `send-to-review` → `approve` → `mark-processed`, then `GET /files/{file_id}/status` for the metadata + full event history.
3. **It runs before you wire S3.** With `API_AUTH_SECRET` unset the auth check is a deliberate no-op, and with the AWS keys unset the S3 object-existence check is skipped (validation still runs on the declared metadata) — so the whole state machine works out of the box. Set the [environment variables](#environment-variables) to enforce auth and confirm objects really exist in your bucket.

## API surface

All endpoints live in the `S3FileIntake` API group (canonical `s3-file-intake`) and require the API secret when `API_AUTH_SECRET` is set (header `X-API-Secret: <secret>` or an `api_secret` field). Every call writes an `api_request_logs` row.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/files/register` | Record an uploaded object's metadata → a `registered` `files` row + event. |
| `POST` | `/files/{file_id}/validate` | Validate type + size (and S3 existence when creds are set) → `validated` or `failed`. |
| `POST` | `/files/{file_id}/send-to-review` | From `validated` → `needs_review` + a pending review row. |
| `POST` | `/files/{file_id}/approve` | From `needs_review` → `approved` (records reviewer + note). |
| `POST` | `/files/{file_id}/reject` | From `needs_review` → `rejected` (requires a note). |
| `POST` | `/files/{file_id}/mark-processed` | From `approved` → `processed`. |
| `GET` | `/files/{file_id}/status` | Metadata, current status, latest review, canonical S3 URL, and full event history. |

## Database Tables

- **files** — one row per file: `s3_key` (unique), `file_name`, `file_type`, `file_size_bytes`, `uploaded_by`, `status`, timestamps.
- **file_events** — append-only audit trail: one row per lifecycle action (`file_id`, `event_type`, `event_payload`, `created_by`).
- **file_reviews** — one row per review: `review_status` (`pending` → `approved` / `rejected`), `reviewer_id`, `review_note`.
- **api_request_logs** — one row per API call (endpoint, requester, status, error), written on success and failure.

## Testing

Run from a deployed workspace with `xano workflow_test run_all`:
- **`s3_file_intake_happy_path`** — register → validate → send-to-review → approve → mark-processed, asserting each status transition and the resulting event trail.
- **`s3_file_intake_reject_path`** — the review-rejection branch and that illegal transitions are refused.

Both run credential-free (the S3 existence check is skipped and the auth check is a no-op when their env vars are unset), so the full state machine is exercised without an AWS account.

## Environment variables

Set these in your Xano workspace (Settings → Environment Variables) to enforce auth and enable the real S3 checks. The state machine runs without them (auth no-op, S3 existence check skipped).

- `S3_BUCKET_NAME` — your bucket; used to build the canonical S3 object URL and for the existence check.
- `AWS_REGION` — the bucket's region; used for the URL and the existence check.
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — used by `validate` to confirm the object exists in S3 (`cloud.aws.s3.get_file_info`). When unset, the existence check is skipped and validation runs on the declared metadata only.
- `API_AUTH_SECRET` — the shared secret every endpoint checks (via `X-API-Secret` header or `api_secret` field). When unset the check is a deliberate no-op so the module runs out of the box; **set it in production.**
