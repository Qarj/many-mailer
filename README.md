# many-mailer

An AWS playground for a mailer-style service. It currently provisions a minimal HTTP API backed by a Lambda function and a DynamoDB table, plus a GitHub Pages test page for quick CORS/hosting checks.

Project site (Pages):
https://qarj.github.io/many-mailer/

## What it does

- Serves a basic HTTP API via API Gateway -> Lambda.
- Stores data in a DynamoDB table (intended for items/entities).
- Provides a simple static test page on GitHub Pages.
- Includes a Cost Explorer helper script to track AWS spend by service and usage.

## Architecture (current)

- API Gateway HTTP API
  - Routes all paths to the Lambda function.
- Lambda (Node.js 20)
  - Minimal router for health/testing.
- DynamoDB table
  - Single primary key: `id` (string).
- CloudWatch Logs
  - 7-day retention for the Lambda log group.

## Lambda behavior

Defined in [lambda-src/index.js](lambda-src/index.js).

- `GET /ping` returns JSON: `{ ok: true, time: <ISO timestamp> }`
- Any other path returns plain text: `many-mailer lambda is alive`

## Infrastructure (Terraform)

Defined in [infra/main.tf](infra/main.tf) with AWS provider config in [infra/providers.tf](infra/providers.tf).

- DynamoDB table: `many-mailer-items`
- Lambda: `many-mailer-api` (Node.js 20)
- API Gateway HTTP API: `many-mailer-http`
- CORS allows:
  - `https://qarj.github.io`
  - `http://localhost:7075`
- Output: `api_base_url` (invoke URL for the deployed stage)

Terraform backend is configured to use an S3 state bucket in [infra/backend.tf](infra/backend.tf).

## GitHub Pages test page

Static page lives at [docs/index.html](docs/index.html). It includes a client-side fetch test against itself to validate hosting and CORS.

## Cost Explorer helper

Script: [scripts/ce.sh](scripts/ce.sh)

- Pretty-prints Cost Explorer results by service and usage.
- Supports MTD, last-7-days, and service+usage drilldowns.
- Avoids passing an empty filter to AWS CE (prevents validation errors).

Docs:

- [dev-notes/cost-explorer.md](dev-notes/cost-explorer.md)
- [dev-notes/cost-explorer-notes.md](dev-notes/cost-explorer-notes.md)

## How to deploy

Prereqs:

- AWS credentials configured for your account.
- Terraform >= 1.6.0.
- Node.js is only needed if you expand the Lambda, not for deployment.

Steps:

1. Build the Lambda artifact (zip the handler):

```sh
mkdir -p infra/artifacts
cd lambda-src
zip -r ../infra/artifacts/lambda.zip .
```

2. Initialize and apply Terraform:

```sh
cd ../infra
terraform init
terraform apply
```

Notes:

- The Terraform backend uses an S3 bucket defined in [infra/backend.tf](infra/backend.tf). Ensure the bucket exists and you have access.
- On success, Terraform outputs `api_base_url` for the HTTP API invoke URL.

## AWS console links

https://console.aws.amazon.com/
https://signin.aws.amazon.com/console
