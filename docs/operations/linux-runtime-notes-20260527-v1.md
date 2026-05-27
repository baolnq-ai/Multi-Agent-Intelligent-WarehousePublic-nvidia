# Linux Runtime Notes: Multi-Agent Intelligent Warehouse

- Date: 2026-05-27
- Status: completed
- Related plan: ../../plans/running/plan-aihub-provider-linux-stability-20260527-v1.md
- Related log: ../../logs/testing/provider-linux-stability-20260527-v1.md

## Port Rule
AI Hub installs use host ports in `6000-6050`. Current defaults are PostgreSQL `6000`, Redis `6001`, Kafka `6002`, etcd `6003`, MinIO API `6004`, MinIO console `6005`, Milvus gRPC `6006`, Milvus HTTP `6007`, backend `6008`, frontend `6009`, nginx `6010` and optional local NIM `6011`.

## Common Linux Issues
- Stop old compose projects before reinstalling to avoid occupied Postgres, Redis, Kafka, MinIO and Milvus ports.
- Use hosted mode on AMD/Windows/Linux without NVIDIA runtime.
- Do not treat a reused database volume as a clean fresh install.
- Keep generated runtime data and local credentials out of commits.

## Verified Output
Existing Hub evidence contains provider lifecycle, login/dashboard and service log screenshots. For release sign-off, rerun a fresh clone full flow after this port pass.
