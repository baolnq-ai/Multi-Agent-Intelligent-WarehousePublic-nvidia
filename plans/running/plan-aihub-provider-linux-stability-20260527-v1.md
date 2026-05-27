# Plan: aihub-provider-linux-stability

- Created: 2026-05-27 00:00
- Updated: 2026-05-27 23:40
- Status: completed
- Related log: logs/testing/provider-linux-stability-20260527-v1.md
- Related doc: docs/operations/linux-runtime-notes-20260527-v1.md

## Goal
Ổn định Multi-Agent Intelligent Warehouse khi AI Hub clone lại repo, tránh port ngoài range `6000-6050` và không phụ thuộc local GPU trong hosted mode.

## Scope
- In: ghi chú Linux, kiểm tra port setup, trạng thái provider evidence, chuẩn bị rerun fresh install nếu cần.
- Out: không commit key thật, không push evidence Hub tổng, không bật local NIM bắt buộc.

## Skills
- testing-skill
- plan-skill
- logging-skill
- documentation-skill
- push-code-skill

## Phases
| Phase | Goal | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Kiểm tra source và commit hiện tại | done | `9558b93` |
| 2 | Ghi chú Linux và port `6000-6050` | done | README, docs/operations |
| 3 | Fresh install full warehouse flow | skipped | stack lớn, cần rerun riêng khi cần full release sign-off |

## Verification
- Existing evidence có login/dashboard và service logs.
- Port defaults và allocator đã được chuẩn hóa về `6000-6050`.

## Close Criteria
- Host ports nằm trong `6000-6050`.
- Dashboard/API/chat hoặc workflow chính có output thật.
- Không lưu secret hoặc dữ liệu runtime vào repo.
