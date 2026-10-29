#!/bin/bash
# Each scenario gets a fresh loopback-only server and disposable databases.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
python_cmd="${VOCAB_PYTHON:-python3}"
node_cmd="${VOCAB_NODE:-node}"
log="$(mktemp "${TMPDIR:-/tmp}/vocab-http-fixture.XXXXXX")"
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  "$python_cmd" - "$log" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
if p.name.startswith('vocab-http-fixture.') and p.is_file(): p.unlink()
PY
}
trap cleanup EXIT
if curl --max-time 2 --silent http://127.0.0.1:18765/ >/dev/null; then
  echo 'Port 18765 is already occupied; refusing to run against an existing service.' >&2
  exit 1
fi
scenarios=(
  tests/test_ui_fixture_cleanup.py
  server/test_scheduled_backup.py
  server/test_restore_api.py
  server/test_guarded_restore_receipt_http.py
  server/test_guarded_checkpoint_receipt_http.py
  server/test_checkpoint_http.py
  server/test_guest_credentials_http.py
  server/test_rate_http.py
  server/test_personal_http.py
  server/test_security_regression.py
  server/test_password_http.py
  server/test_posterior_http.py
  server/test_state_capacity.py
  server/test_state_segments_http.py
  server/test_state_revision_http.py
  server/test_streak_write_validation_http.py
  server/test_state_changes_http.py
  server/test_delta_upload_http.py
  server/test_experimental_large_delta_http.py
  server/test_experimental_large_restore_http.py
  server/test_experimental_large_checkpoint_http.py
  server/test_experimental_large_checkpoint_cancel_http.py
  server/test_experimental_large_restore_cancel_http.py
  server/test_delta_staging_http.py
  server/test_generation_http.py
  server/test_scheduler_resolve_http.py
  server/test_state_snapshot_http.py
  server/test_stored_snapshot_http.py
  server/test_oversize_stored_snapshot_http.py
  server/test_snapshot_retry_http.py
  server/test_snapshot_limits_http.py
  tests/web_study_e2e.cjs
  tests/web_daily_budget_e2e.cjs
  tests/web_daily_budget_sync_e2e.cjs
  tests/web_stale_daily_plan_e2e.cjs
  tests/web_choice_evidence_e2e.cjs
  tests/quiz_word_identity_http.py
  tests/web_quiz_identity_e2e.cjs
  tests/web_acceptance_atomic_e2e.cjs
  tests/web_today_plan_check.cjs
  tests/web_today_plan_e2e.cjs
  tests/web_fsrs_check.cjs
  tests/web_undo_check.cjs
  tests/web_shadow_score_check.cjs
  tests/fsrs_replay_check.py
  tests/fsrs_learning_intervals_http.py
  tests/web_sentence_alternatives_e2e.cjs
  tests/web_sentence_race_e2e.cjs
  tests/web_sentence_layout_e2e.cjs
  tests/web_early_consolidation_e2e.cjs
  tests/web_ux_regression_e2e.cjs
  tests/web_conflict_preservation_e2e.cjs
  tests/web_quota_log_preservation_e2e.cjs
  tests/web_single_page_sync_race_e2e.cjs
  tests/web_large_local_store_e2e.cjs
  tests/web_normal_durable_store_e2e.cjs
  tests/web_normal_v5_upgrade_e2e.cjs
  tests/web_normal_prepared_transition_race_e2e.cjs
  tests/web_normal_session_lease_e2e.cjs
  tests/web_normal_enable_settings_e2e.cjs
  tests/web_normal_auto_resume_e2e.cjs
  tests/web_normal_active_quota_e2e.cjs
  tests/web_normal_active_online_e2e.cjs
  tests/web_normal_active_source_loss_e2e.cjs
  tests/web_normal_source_recovery_e2e.cjs
  tests/web_normal_backup_restore_e2e.cjs
  tests/web_normal_backup_restore_process_e2e.cjs
  tests/web_normal_backup_restore_conflict_e2e.cjs
  tests/web_normal_checkpoint_e2e.cjs
  tests/web_normal_checkpoint_process_e2e.cjs
  tests/web_normal_checkpoint_conflict_e2e.cjs
  tests/web_normal_checkpoint_history_e2e.cjs
  tests/web_normal_reload_e2e.cjs
  tests/web_normal_transition_archive_e2e.cjs
  tests/web_normal_reload_conflict_e2e.cjs
  tests/web_normal_reload_process_e2e.cjs
  tests/web_normal_active_offline_e2e.cjs
  tests/web_normal_active_ui_process_e2e.cjs
  tests/web_normal_prepared_legacy_race_e2e.cjs
  tests/web_normal_fence_marker_restore_e2e.cjs
  tests/web_normal_receipt_atomic_e2e.cjs
  tests/web_normal_migration_process_e2e.cjs
  tests/web_normal_transition_process_e2e.cjs
  tests/web_normal_transition_cancel_e2e.cjs
  tests/web_normal_prepared_upload_process_e2e.cjs
  tests/web_normal_prepared_pull_process_e2e.cjs
  tests/web_normal_prepared_rebase_process_e2e.cjs
  tests/web_large_migration_e2e.cjs
  tests/web_large_snapshot_saved_e2e.cjs
  tests/web_large_snapshot_process_e2e.cjs
  tests/web_large_snapshot_race_e2e.cjs
  tests/web_large_synced_journal_e2e.cjs
  tests/web_large_sync_live_e2e.cjs
  tests/web_large_sync_process_e2e.cjs
  tests/web_large_restore_intent_process_e2e.cjs
  tests/web_small_large_restore_process_e2e.cjs
  tests/web_large_checkpoint_process_e2e.cjs
  tests/web_large_checkpoint_cancel_process_e2e.cjs
  tests/web_large_restore_cancel_process_e2e.cjs
  tests/web_large_restore_upgrade_e2e.cjs
  tests/web_large_sync_pull_e2e.cjs
  tests/web_large_active_e2e.cjs
  tests/web_large_reload_e2e.cjs
  tests/web_large_restore_archives_e2e.cjs
  tests/web_large_reload_conflict_e2e.cjs
  tests/web_large_reload_process_e2e.cjs
  tests/web_large_reload_near_limit_e2e.cjs
  tests/web_large_active_process_e2e.cjs
  tests/web_large_resume_offline_e2e.cjs
  tests/web_large_resume_corrupt_e2e.cjs
  tests/web_large_resume_pref_failure_e2e.cjs
  tests/web_large_background_save_e2e.cjs
  tests/web_large_background_conflict_e2e.cjs
  tests/web_large_background_quota_e2e.cjs
  tests/web_large_quota_log_preservation_e2e.cjs
  tests/web_large_pull_process_e2e.cjs
  tests/web_experimental_large_push_e2e.cjs
  tests/web_save_failure_sync_e2e.cjs
  tests/web_unconfirmed_server_e2e.cjs
  tests/web_unconfirmed_process_e2e.cjs
  tests/web_first_read_conflict_e2e.cjs
  tests/web_account_slots_e2e.cjs
  tests/web_large_journal_e2e.cjs
  tests/web_large_journal_process_e2e.cjs
  tests/web_forecast_timezone_e2e.cjs
  tests/web_retention_e2e.cjs
  tests/web_restore_e2e.cjs
  tests/web_restore_session_e2e.cjs
  tests/web_guarded_restore_e2e.cjs
  tests/web_mutation_delete_race_e2e.cjs
  tests/web_mutation_response_loss_e2e.cjs
  tests/web_mutation_preview_tab_e2e.cjs
  tests/web_backup_quality_e2e.cjs
  tests/web_delta_sync_e2e.cjs
  tests/web_bootstrap_process_e2e.cjs
  tests/web_delta_staged_e2e.cjs
  tests/web_delta_multiops_e2e.cjs
  tests/web_staged_upload_process_restart_e2e.cjs
  tests/web_delta_read_e2e.cjs
  tests/web_compact_retention_e2e.cjs
  tests/web_incremental_pull_e2e.cjs
  tests/web_pull_process_restart_e2e.cjs
  tests/web_delta_fence_retention_e2e.cjs
  tests/web_noop_restore_fence_e2e.cjs
  tests/web_settings_sync_e2e.cjs
  tests/web_personal_rejection_e2e.cjs
  tests/web_placement_resume_e2e.cjs
  tests/web_done_capacity_e2e.cjs
  tests/web_password_auth_e2e.cjs
  tests/web_review_navigation_e2e.cjs
  tests/web_learning_navigation_e2e.cjs
  tests/web_queue_pagination_e2e.cjs
  tests/web_meaning_retry_e2e.cjs
  tests/web_manual_sync_e2e.cjs
  tests/web_offline_integration.cjs
  tests/web_offline_schedule_e2e.cjs
)
for scenario in "${scenarios[@]}"; do
  fixture_nonce="$("$python_cmd" -c 'import uuid; print(uuid.uuid4().hex)')"
  VOCAB_UI_FIXTURE_NONCE="$fixture_nonce" "$python_cmd" tests/ui_stub_server.py >"$log" 2>&1 &
  fixture_pid=$!
  ready=0
  for _ in $(seq 1 30); do
    if [[ "$(curl --max-time 2 --silent http://127.0.0.1:18765/api/v1/__ui_fixture/identity || true)" == "{\"fixture\":\"vocab-ui-isolated-v1\",\"nonce\":\"$fixture_nonce\"}" ]]; then ready=1; break; fi
    kill -0 "$fixture_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then cat "$log" >&2; echo 'Isolated fixture did not start.' >&2; exit 1; fi
  echo "Running $scenario"
  if [[ "$scenario" == *.py ]]; then "$python_cmd" "$scenario"; else "$node_cmd" "$scenario"; fi
  kill "$fixture_pid"
  wait "$fixture_pid" || true
  fixture_pid=""
done
