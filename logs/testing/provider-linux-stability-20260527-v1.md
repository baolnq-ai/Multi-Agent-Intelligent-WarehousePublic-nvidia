# Log: provider Linux stability 2026-05-27

- Started: 2026-05-27
- Finished: 2026-05-27
- Status: completed
- Plan: plans/running/plan-aihub-provider-linux-stability-20260527-v1.md
- Doc: docs/operations/linux-runtime-notes-20260527-v1.md

## Mục Tiêu
Theo dõi ổn định Linux cho Multi-Agent Intelligent Warehouse và ghi rõ phần còn cần port/fresh clone verification.

## Command Chính
- Rà source, scripts và evidence hiện có.
- Ghi chú lỗi Linux thường gặp.
- Chuẩn hóa phase fix port allocator `6000-6050`.

## Kết Quả
- Source hiện tại ở `9558b93` trên `origin/main`.
- Existing evidence có lifecycle, login/dashboard và service log.
- Script và compose defaults đã chuyển sang host ports `6000-6011`.

## Lỗi Linux Hay Gặp
- Compose stack lớn có nhiều service infra, dễ chiếm port cũ như Postgres, Redis, Kafka, MinIO, Milvus.
- Local NIM/GPU profile không phù hợp AMD/Windows; hosted API mode là đường kiểm thử mặc định.
- Database seed/default password chỉ dùng dev; không commit secret thật.
- Stop/clean không hết volume/network có thể làm fresh install dùng state cũ.

## Rủi Ro Còn Lại
- Stack lớn nên nên rerun fresh clone full flow riêng trước release sign-off tiếp theo.
