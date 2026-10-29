#!/bin/bash
# Runs only on a designated booted simulator and a separate throwaway app identifier.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then echo 'Usage: run_ios_ui_regression.sh SIMULATOR_UDID [guest|static-swap|reminder|reminder-sync|account|offline|normal-interop|normal-recovery-interop|normal-backup-interop|normal-checkpoint-interop|normal-reload-interop|large-reload-interop|large-reload-oversize-interop|recovery|recovery-relogin|file|pull-fence|missing-delta|incremental-read|incremental-pruned|interop|replace|personal|identity|legacy|legacy-date|forecast|retention|budget|undo|queue|queue-switch|queue-pages|queue-end|acceptance-switch|meaning|manual-sync|delta-replay|staged-replay|staged-large-replay|large-login|large-restore-resume|large-restore-conflict|large-restore-new|large-restore-interrupt|large-checkpoint-interrupt|large-checkpoint-cancel-interrupt|large-restore-cancel-interrupt|backup-scheduler|disk-failure|fsrs-relogin]' >&2; exit 2; fi
case "${2:-guest}" in
  guest) method=testGuestPlacementAndFirstStudy ;;
  reminder) method=testReminderDeniedIsVisible ;;
  reminder-sync) method=testSyncedReminderAppliesImmediately ;;
  account) method=testAccountRegistrationAndLogin ;;
  offline) method=testOfflineReviewReplay ;;
  recovery) method=testServerReloadConflictAndBackup ;;
  recovery-relogin) method=testReloadPreviewDoesNotCrossRelogin ;;
  file) method=testFileBackupAndRestore ;;
  pull-fence) method=testPulledStateRejectsDatabaseRotation ;;
  missing-delta) method=testMissingDeltaRecordRecovery ;;
  incremental-read) method=testIncrementalReadAcrossLogin ;;
  incremental-pruned) method=testPrunedIncrementalReadFallsBack ;;
  interop|normal-interop|normal-recovery-interop) method=testWebSettingsAndHistoryCheckpoint ;;
  normal-backup-interop|normal-checkpoint-interop|normal-reload-interop|large-reload-interop) method=testWebRestoredSettingsSync ;;
  large-reload-oversize-interop) method=testWebLargeReloadSettingsSync ;;
  replace) method=testReplacementPlacementResume ;;
  personal) method=testPersonalSentenceRejection ;;
  static-swap) method=testStaticSentenceSwapFailureKeepsSentence ;;
  identity) method=testReusedAccountIdentityIsolation ;;
  legacy) method=testLegacySlotConfirmationAndRestore ;;
  legacy-date) method=testLegacyDateOnlyCardIsReviewable ;;
  forecast) method=testForecastShowsOverdueLegacyCard ;;
  retention) method=testRetentionUsesActualReviewTime ;;
  budget) method=testDailyCapacityAndDoneScreen ;;
  undo) method=testReviewUndoAndExitDuringRequest ;;
  queue) method=testQueuePreparationDoesNotReopenAfterNavigation ;;
  queue-switch) method=testQueuePreparationDoesNotCrossAccounts ;;
  queue-pages) method=testQueuePaginationRetriesAfterFailure ;;
  queue-end) method=testQueueUsesFinalPartialVocabularyPage ;;
  acceptance-switch) method=testAcceptanceResponseDoesNotCrossAccounts ;;
  meaning) method=testMissingMeaningRetryAndDefer ;;
  manual-sync) method=testManualSyncMergeAndOversizeRecovery ;;
  delta-replay) method=testDeltaReplayAfterProcessTermination ;;
  staged-replay) method=testStagedDeltaReplayAfterProcessTermination ;;
  staged-large-replay) method=testExperimentalLargeReplayAfterProcessTermination ;;
  large-login) method=testExperimentalLargeFirstLogin ;;
  large-restore-resume) method=testExperimentalLargeRestoreResume ;;
  large-restore-conflict) method=testExperimentalLargeRestoreLocalConflict ;;
  large-restore-new) method=testExperimentalLargeRestoreFromFile ;;
  large-restore-interrupt) method=testExperimentalLargeRestoreInterrupted ;;
  large-checkpoint-interrupt) method=testExperimentalLargeCheckpointInterrupted ;;
  large-checkpoint-cancel-interrupt) method=testExperimentalLargeCheckpointCancelInterrupted ;;
  large-restore-cancel-interrupt) method=testExperimentalLargeRestoreCancelInterrupted ;;
  backup-scheduler) method=testBackupWarnsMissingScheduler ;;
  disk-failure) method=testDiskFailureKeepsUnsavedAccountState ;;
  fsrs-relogin) method=testOldFsrsResponseCannotModifyReloggedSession ;;
  *) echo 'Unknown UI test selection' >&2; exit 2 ;;
esac
udid="$1"
test_base="${VOCAB_UI_TEST_API:-http://127.0.0.1:18765}"
[[ "$test_base" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo 'Fixture must use loopback HTTP and an explicit port.' >&2; exit 1; }
if [[ "$test_base" != 'http://127.0.0.1:18765' && "${2:-guest}" != 'guest' && "${2:-guest}" != 'static-swap' && "${2:-guest}" != 'account' && "${2:-guest}" != 'offline' && "${2:-guest}" != 'normal-interop' && "${2:-guest}" != 'normal-recovery-interop' && "${2:-guest}" != 'normal-backup-interop' && "${2:-guest}" != 'normal-checkpoint-interop' && "${2:-guest}" != 'normal-reload-interop' && "${2:-guest}" != 'large-reload-interop' && "${2:-guest}" != 'large-reload-oversize-interop' && "${2:-guest}" != 'retention' && "${2:-guest}" != 'forecast' && "${2:-guest}" != 'legacy-date' && "${2:-guest}" != 'meaning' && "${2:-guest}" != 'reminder' && "${2:-guest}" != 'reminder-sync' && "${2:-guest}" != 'acceptance-switch' && "${2:-guest}" != 'disk-failure' && "${2:-guest}" != 'fsrs-relogin' && "${2:-guest}" != 'manual-sync' && "${2:-guest}" != 'delta-replay' && "${2:-guest}" != 'staged-replay' && "${2:-guest}" != 'staged-large-replay' && "${2:-guest}" != 'large-login' && "${2:-guest}" != 'large-restore-resume' && "${2:-guest}" != 'large-restore-conflict' && "${2:-guest}" != 'large-restore-new' && "${2:-guest}" != 'large-restore-interrupt' && "${2:-guest}" != 'large-checkpoint-interrupt' && "${2:-guest}" != 'large-checkpoint-cancel-interrupt' && "${2:-guest}" != 'large-restore-cancel-interrupt' && "${2:-guest}" != 'backup-scheduler' && "${2:-guest}" != 'recovery-relogin' && "${2:-guest}" != 'recovery' && "${2:-guest}" != 'file' && "${2:-guest}" != 'pull-fence' && "${2:-guest}" != 'missing-delta' && "${2:-guest}" != 'incremental-read' && "${2:-guest}" != 'incremental-pruned' ]]; then
  echo 'Alternate fixture port is supported only for isolated static-swap, offline, normal-interop, normal-recovery-interop, retention, forecast, legacy-date, meaning, reminder, reminder-sync, acceptance-switch, disk-failure, fsrs-relogin, manual-sync, delta-replay, staged-replay, staged-large-replay, large-login, large-restore-resume, large-restore-conflict, large-restore-new, large-restore-interrupt, backup-scheduler, recovery-relogin, recovery, file, pull-fence, missing-delta, incremental-read and incremental-pruned scenarios.' >&2; exit 1
fi
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/vocab-ui.XXXXXX")"
test_id="com.zorro.vocab.regression.$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
watch_pid=""
cleanup() {
  if [[ -n "$watch_pid" ]]; then kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; fi
  xcrun simctl uninstall "$udid" "$test_id.uitests.xctrunner" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$test_id" >/dev/null 2>&1 || true
  /usr/bin/python3 - "$test_tmp" <<'PY'
import shutil, sys
from pathlib import Path
p=Path(sys.argv[1])
if p.name.startswith("vocab-ui.") and p.is_dir(): shutil.rmtree(p)
PY
}
trap cleanup EXIT
cp -R "$root/ios" "$test_tmp/ios"
/usr/bin/python3 - "$test_tmp/ios" "$test_base" <<'PYCODE'
import sys
from pathlib import Path
root = Path(sys.argv[1])
for relative in ('VocabUITests/VocabUITests.swift', 'VocabApp/Config.swift'):
    path = root / relative
    text = path.read_text()
    expected = 'http://127.0.0.1:18765'
    if expected not in text:
        raise SystemExit(f'Missing expected fixture address in {relative}; refusing to run')
    path.write_text(text.replace(expected, sys.argv[2].rstrip('/')))
PYCODE
/usr/bin/python3 - "$test_tmp/ios/VocabApp.xcodeproj/project.pbxproj" "$test_id" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
s=s.replace('PRODUCT_BUNDLE_IDENTIFIER = com.zorro.vocab.uitests;', f'PRODUCT_BUNDLE_IDENTIFIER = {sys.argv[2]}.uitests;')
s=s.replace('PRODUCT_BUNDLE_IDENTIFIER = com.zorro.vocab;', f'PRODUCT_BUNDLE_IDENTIFIER = {sys.argv[2]};')
p.write_text(s)
PY
fixture=$(curl --fail --silent "$test_base/api/v1/__ui_fixture" || true)
[[ "$fixture" == '{"fixture":"vocab-ui-isolated-v1"}' ]] || { echo 'Start tests/ui_stub_server.py against an isolated data directory first.' >&2; exit 1; }
if [[ "${2:-guest}" == "interop" || "${2:-guest}" == "normal-interop" || "${2:-guest}" == "normal-recovery-interop" ]]; then VOCAB_TEST_BASE="$test_base" VOCAB_UI_NORMAL_ACTIVE="$([[ "${2:-guest}" == normal-* ]] && echo 1 || echo 0)" VOCAB_UI_NORMAL_RECOVERY="$([[ "${2:-guest}" == "normal-recovery-interop" ]] && echo 1 || echo 0)" node "$root/tests/web_ios_settings_e2e.cjs" setup; fi
if [[ "${2:-guest}" == "normal-backup-interop" || "${2:-guest}" == "normal-checkpoint-interop" || "${2:-guest}" == "normal-reload-interop" ]]; then
  VOCAB_TEST_BASE="$test_base" VOCAB_UI_WEB_PROFILE="$test_tmp/web-profile" VOCAB_UI_NORMAL_CHECKPOINT="$([[ "${2:-guest}" == "normal-checkpoint-interop" ]] && echo 1 || echo 0)" VOCAB_UI_NORMAL_RELOAD="$([[ "${2:-guest}" == "normal-reload-interop" ]] && echo 1 || echo 0)" node "$root/tests/web_ios_normal_restore_e2e.cjs" setup
fi
if [[ "${2:-guest}" == "large-reload-interop" || "${2:-guest}" == "large-reload-oversize-interop" ]]; then
  VOCAB_TEST_BASE="$test_base" VOCAB_UI_WEB_PROFILE="$test_tmp/web-profile" VOCAB_UI_LARGE_KEEP_OVERSIZE="$([[ "${2:-guest}" == "large-reload-oversize-interop" ]] && echo 1 || echo 0)" node "$root/tests/web_ios_large_reload_e2e.cjs" setup
fi
xcode_args=(-project "$test_tmp/ios/VocabApp.xcodeproj" -scheme VocabUIRegression -configuration Debug
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$test_tmp/derived" CODE_SIGNING_ALLOWED=NO)
if [[ "${2:-guest}" == "legacy" ]]; then
  curl --fail --silent --output /dev/null -X POST http://127.0.0.1:18765/api/v1/__ui_fixture/interop-case
  xcodebuild "${xcode_args[@]}" build-for-testing
  xcrun simctl install "$udid" "$test_tmp/derived/Build/Products/Debug-iphonesimulator/VocabApp.app"
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json,sys,urllib.request
from pathlib import Path
base='http://127.0.0.1:18765'
def request(path, body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path, None if body is None else json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)
seed=request('/api/v1/__ui_fixture/interop-case')
auth=request('/api/v1/auth/login', {'username':seed['username'],'password':seed['password']})
state=request('/api/v1/me/state', token=seed['token'])['state']
state['cards']={'pear':state['cards']['apple']}
root=Path(sys.argv[1])/'Documents';root.mkdir(exist_ok=True)
slot='vocab_state_u'+str(auth['user']['id'])
(root/(slot+'.json')).write_text(json.dumps(state))
(root/(slot+'.user')).write_text(seed['username'])
PYCODE
  xcodebuild "${xcode_args[@]}" "-only-testing:VocabUITests/VocabUITests/$method" test-without-building
elif [[ "${2:-guest}" == "staged-replay" || "${2:-guest}" == "staged-large-replay" || "${2:-guest}" == "large-login" || "${2:-guest}" == "large-restore-resume" || "${2:-guest}" == "large-restore-conflict" || "${2:-guest}" == "large-restore-new" || "${2:-guest}" == "large-restore-interrupt" || "${2:-guest}" == "large-checkpoint-interrupt" || "${2:-guest}" == "large-checkpoint-cancel-interrupt" || "${2:-guest}" == "large-restore-cancel-interrupt" ]]; then
  xcodebuild "${xcode_args[@]}" build-for-testing
  xcrun simctl install "$udid" "$test_tmp/derived/Build/Products/Debug-iphonesimulator/VocabApp.app"
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  swiftc "$root/ios/VocabApp/Models.swift" "$root/ios/VocabApp/StudyEngine.swift" "$root/ios/VocabApp/APIClient.swift" "$root/tests/iOSStagedUploadCheck.swift" -o "$test_tmp/staged-helper"
  /usr/bin/python3 - "$app_data" "$udid" "$test_base" "$test_tmp/staged-helper" "${2:-guest}" <<'PYCODE'
import json, os, re, subprocess, sys, urllib.request
from pathlib import Path
root, udid, base, helper, mode = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3].rstrip('/'), sys.argv[4], sys.argv[5]
if f'/Devices/{udid}/data/Containers/Data/Application/' not in str(root): raise SystemExit('Unexpected simulator container')
def post(path, body):
    req=urllib.request.Request(base+path,json.dumps(body).encode(),{'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=30) as response: return json.load(response)
seed=post('/api/v1/__ui_fixture/staged-ui-setup',{})
if mode in ('staged-large-replay','large-login','large-restore-resume','large-restore-conflict','large-restore-new','large-restore-interrupt','large-checkpoint-interrupt','large-checkpoint-cancel-interrupt','large-restore-cancel-interrupt'): post('/api/v1/__ui_fixture/experimental-large-deltas',{'enabled':True})
auth=post('/api/v1/auth/login',{'username':seed['username'],'password':seed['password']})
account=auth['user']['account_id']
if not re.fullmatch(r'[a-f0-9]{32}',account): raise SystemExit('Invalid account identity')
env={**os.environ,'VOCAB_FIXTURE_TOKEN':seed['token'],'VOCAB_TEST_BASE':base}
args=[helper,'--seed-server-large',account] if mode in ('large-login','large-restore-new','large-restore-interrupt','large-checkpoint-interrupt','large-checkpoint-cancel-interrupt','large-restore-cancel-interrupt') else [helper,'--seed-ui-large-restore' if mode in ('large-restore-resume','large-restore-conflict') else ('--seed-ui-large' if mode == 'staged-large-replay' else '--seed-ui'),str(root/'Documents'),account]
subprocess.run(args,env=env,check=True)
PYCODE
  xcodebuild "${xcode_args[@]}" "-only-testing:VocabUITests/VocabUITests/$method" test-without-building
  if [[ "${2:-guest}" == "large-restore-new" || "${2:-guest}" == "large-restore-interrupt" || "${2:-guest}" == "large-checkpoint-interrupt" ]]; then
    app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
    /usr/bin/python3 - "$app_data" "${2:-guest}" <<'PYCODE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
slots=list(root.glob('vocab_state_a*.json')); assert len(slots)==1
state=json.loads(slots[0].read_bytes()); assert state['restoreEpoch']==1
records=list((root/'VocabDelta').glob('delta-*.json')); assert len(records)==1
record=json.loads(records[0].read_bytes()); assert record['restore_epoch']==1 and record['server']['settings']==state['settings']
assert not list((root/'VocabDelta').glob('large-restore-*'))
backups=list((root/'VocabDelta').glob('before-large-restore-*.json')); assert len(backups)==1
old=json.loads(backups[0].read_bytes())
if sys.argv[2]=='large-checkpoint-interrupt':
    assert old['settings']==state['settings']
    print('PASS large checkpoint preserved settings and the pre-checkpoint slot')
else:
    assert old['settings']['newPerDay'] != state['settings']['newPerDay']
    print('PASS imported large backup restored original setting and preserved pre-restore slot')
PYCODE
  fi
  if [[ "${2:-guest}" == "large-checkpoint-cancel-interrupt" || "${2:-guest}" == "large-restore-cancel-interrupt" ]]; then
    app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
    /usr/bin/python3 - "$app_data" <<'PYCODE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
slots=list(root.glob('vocab_state_a*.json')); assert len(slots)==1
state=json.loads(slots[0].read_bytes()); assert state.get('restoreEpoch',0)==0
records=list((root/'VocabDelta').glob('delta-*.json')); assert len(records)==1
record=json.loads(records[0].read_bytes()); assert record['restore_epoch']==0
assert not list((root/'VocabDelta').glob('large-restore-*'))
assert len(state.get('personalizedWeak',''))==7*1024*1024
print('PASS cancelled checkpoint kept the original slot and released the fence')
PYCODE
  fi
  if [[ "${2:-guest}" == "large-restore-conflict" ]]; then
    app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
    /usr/bin/python3 - "$app_data" <<'PYCODE'
import base64,json,sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
slots=list(root.glob('vocab_state_a*.json')); records=list((root/'VocabDelta').glob('large-restore-*.json'))
assert len(slots)==1 and len(records)==1
local=json.loads(slots[0].read_bytes()); intent=json.loads(records[0].read_bytes())
previous=json.loads(base64.b64decode(intent['previous']))
assert local['settings']['newPerDay'] != previous['settings']['newPerDay']
assert 'restore_ui_marker' not in local['cards']
assert list((root/'VocabDelta').glob('large-restore-*.guard'))
print('PASS restore conflict retained local setting and recovery fence')
PYCODE
  fi
  if [[ "${2:-guest}" == "large-restore-resume" ]]; then
    app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
    /usr/bin/python3 - "$app_data" <<'PYCODE'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
slots=list(root.glob('vocab_state_a*.json')); assert len(slots)==1
state=json.loads(slots[0].read_bytes()); assert 'restore_ui_marker' in state['cards'] and state['restoreEpoch']==1
records=list((root/'VocabDelta').glob('delta-*.json')); assert len(records)==1
record=json.loads(records[0].read_bytes()); assert record['restore_epoch']==1 and 'restore_ui_marker' in record['server']['cards']
assert not list((root/'VocabDelta').glob('large-restore-*'))
backups=list((root/'VocabDelta').glob('before-large-restore-*.json')); assert len(backups)==1
assert 'restore_ui_marker' not in json.loads(backups[0].read_bytes())['cards']
print('PASS app resumed large restore, released fence and preserved original slot')
PYCODE
  fi
  if [[ "${2:-guest}" == "large-login" ]]; then
    app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
    /usr/bin/python3 - "$app_data" <<'PYCODE'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
slots=list(root.glob('vocab_state_a*.json')); assert len(slots)==1, f'expected one account slot, found {len(slots)} in {root}'
raw=slots[0].read_bytes(); state=json.loads(raw)
assert len(raw)>8*1024*1024 and len(state['personalized']['apple']['text'])==2100*1024
records=list((root/'VocabDelta').glob('delta-*.json')); assert len(records)==1, f'expected one baseline, found {len(records)}'
record=json.loads(records[0].read_bytes()); assert record.get('pending') is None and record.get('pull') is None and record.get('compactPull') is None
assert record['server']['personalized']['apple']['text']==state['personalized']['apple']['text']
print('PASS fresh simulator persisted large state and verified baseline')
PYCODE
  fi
elif [[ "${2:-guest}" == "disk-failure" ]]; then
  xcodebuild "${xcode_args[@]}" build-for-testing
  xcrun simctl install "$udid" "$test_tmp/derived/Build/Products/Debug-iphonesimulator/VocabApp.app"
  /usr/bin/python3 "$root/tests/ios_disk_failure_watcher.py" "$udid" "$test_id" "$test_base" &
  watch_pid=$!
  xcodebuild "${xcode_args[@]}" "-only-testing:VocabUITests/VocabUITests/$method" test-without-building
  wait "$watch_pid"
  watch_pid=""
elif [[ "${2:-guest}" == "missing-delta" ]]; then
  xcodebuild "${xcode_args[@]}" build-for-testing
  xcrun simctl install "$udid" "$test_tmp/derived/Build/Products/Debug-iphonesimulator/VocabApp.app"
  /usr/bin/python3 "$root/tests/ios_missing_delta_watcher.py" "$udid" "$test_id" "$test_base" &
  watch_pid=$!
  xcodebuild "${xcode_args[@]}" "-only-testing:VocabUITests/VocabUITests/$method" test-without-building
  wait "$watch_pid"
  watch_pid=""
else
  xcodebuild "${xcode_args[@]}" "-only-testing:VocabUITests/VocabUITests/$method" test
fi

if [[ "${2:-guest}" == "staged-replay" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
records=list((root/'VocabDelta').glob('delta-*.json'))
states=list(root.glob('vocab_state_a*.json'))
assert len(records)==1 and len(states)==1, (len(records),len(states))
record=json.loads(records[0].read_text()); state=json.loads(states[0].read_text())
assert record.get('pending') is None
assert len(state.get('personalizedWeak',''))==2100*1024
assert len(state.get('cards',{}))==2101
print('PASS staged batch cleared and large local view retained after simulator restart')
PYCODE
fi

if [[ "${2:-guest}" == "acceptance-switch" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
states = [json.loads(path.read_text()) for path in root.glob('vocab_state_a*.json')]
old = next(s for s in states if set(s.get('cards', {})) == {'apple'})
new = next(s for s in states if set(s.get('cards', {})) == {'banana', 'cherry'})
assert old.get('quizProgressDay') and 'apple' in old.get('quizCompleted', [])
assert sum(x.get('kind') == 'review' and x.get('word') == 'apple' for x in old.get('log', [])) == 1
assert 'apple' not in new.get('quizCompleted', [])
assert not any(x.get('word') == 'apple' for x in new.get('log', []))
print('PASS acceptance answer retained once in the old account and absent from the new account')
PYCODE
fi

if [[ "${2:-guest}" == "queue-switch" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
states = [json.loads(path.read_text()) for path in root.glob('vocab_state_a*.json')]
card_sets = {frozenset(state.get('cards', {})) for state in states}
assert frozenset({'apple'}) in card_sets, 'old account local state missing or changed'
assert frozenset({'banana', 'cherry'}) in card_sets, 'new account local state missing or changed'
print('PASS both account slots remain isolated after delayed queue response')
PYCODE
fi

if [[ "${2:-guest}" == "recovery" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
backups = list((root / 'VocabBackups').glob('before-restore-a*.json'))
states = list(root.glob('vocab_state_a*.json'))
assert len(backups) == 1 and len(states) == 1, (len(backups), len(states))
before = json.loads(backups[0].read_text())
after = json.loads(states[0].read_text())
assert set(before['cards']) == {'apple'}
assert set(after['cards']) == {'apple', 'banana', 'cherry'}
print('PASS local pre-reload backup and merged state retained')
PY
fi
if [[ "${2:-guest}" == "missing-delta" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
backups = list((root / 'VocabBackups').glob('before-restore-a*.json'))
states = list(root.glob('vocab_state_a*.json'))
assert len(backups) == 1 and len(states) == 1, (len(backups), len(states))
assert set(json.loads(backups[0].read_text())['cards']) == {'apple'}
assert set(json.loads(states[0].read_text())['cards']) == {'apple'}
assert not list((root / 'VocabDelta').glob('delta-*.guard'))
print('PASS missing-record warning, local backup and explicit reload')
PY
fi
if [[ "${2:-guest}" == "offline" ]]; then
  VOCAB_TEST_BASE="$test_base" node "$root/tests/web_ios_offline_review_e2e.cjs"
fi

if [[ "${2:-guest}" == "interop" || "${2:-guest}" == "normal-interop" || "${2:-guest}" == "normal-recovery-interop" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
backups = list((root / 'VocabBackups').glob('before-restore-a*.json'))
states = list(root.glob('vocab_state_a*.json'))
assert len(backups) == 1 and len(states) == 1
before = json.loads(backups[0].read_text())
after = json.loads(states[0].read_text())
assert before['settings']['newPerDay'] == after['settings']['newPerDay'] == 20
assert before['settings']['dailyCap'] == after['settings']['dailyCap'] == 30
assert after['restoreEpoch'] == 1
print('PASS local pre-checkpoint backup and settings')
PY
  VOCAB_TEST_BASE="$test_base" node "$root/tests/web_ios_settings_e2e.cjs" verify
fi
if [[ "${2:-guest}" == "normal-backup-interop" || "${2:-guest}" == "normal-checkpoint-interop" || "${2:-guest}" == "normal-reload-interop" ]]; then
  VOCAB_TEST_BASE="$test_base" VOCAB_UI_WEB_PROFILE="$test_tmp/web-profile" node "$root/tests/web_ios_normal_restore_e2e.cjs" verify
fi
if [[ "${2:-guest}" == "large-reload-interop" || "${2:-guest}" == "large-reload-oversize-interop" ]]; then
  VOCAB_TEST_BASE="$test_base" VOCAB_UI_WEB_PROFILE="$test_tmp/web-profile" VOCAB_UI_LARGE_KEEP_OVERSIZE="$([[ "${2:-guest}" == "large-reload-oversize-interop" ]] && echo 1 || echo 0)" node "$root/tests/web_ios_large_reload_e2e.cjs" verify
fi
if [[ "${2:-guest}" == "file" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]) / 'Documents'
backups = list((root / 'VocabBackups').glob('before-restore-a*.json'))
states = list(root.glob('vocab_state_a*.json'))
assert len(backups) == 2 and len(states) == 1, (len(backups), len(states))
before = [set(json.loads(path.read_text())['cards']) for path in backups]
assert {'apple'} in before and {'apple', 'banana'} in before
assert set(json.loads(states[0].read_text())['cards']) == {'apple'}
print('PASS local pre-reload and pre-import backups and restored state retained')
PY
fi
if [[ "${2:-guest}" == "personal" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PY'
import json, sys
from pathlib import Path
states = list((Path(sys.argv[1]) / 'Documents').glob('vocab_state_a*.json'))
assert len(states) == 1
state = json.loads(states[0].read_text())
assert 'An old sentence.' in state['rejectedPersonalized']['apple']
assert state['personalized']['apple']['text'] == 'Apple is on the table.'
assert any(job['weakWords'] == ['apple'] and job['status'] == 'complete' for job in state.get('personalJobs', []))
print('PASS local sentence rejection and completed replacement retained')
PY
fi

if [[ "${2:-guest}" == "identity" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json,sys
from pathlib import Path
states = list((Path(sys.argv[1]) / 'Documents').glob('vocab_state_a*.json'))
assert len(states) == 2, len(states)
cards = [set(json.loads(p.read_text())['cards']) for p in states]
assert {'apple'} in cards and {'banana', 'cherry'} in cards
print('PASS reused identity kept account slots separate')
PYCODE
fi

if [[ "${2:-guest}" == "legacy" ]]; then
  app_data="$(xcrun simctl get_app_container "$udid" "$test_id" data)"
  /usr/bin/python3 - "$app_data" <<'PYCODE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])/'Documents'
old=list(root.glob('vocab_state_u*.json'))
current=list(root.glob('vocab_state_a*.json'))
backups=list((root/'VocabBackups').glob('before-restore-a*.json'))
assert len(old)==len(current)==len(backups)==1
assert set(json.loads(old[0].read_text())['cards']) == {'pear'}
assert set(json.loads(current[0].read_text())['cards']) == {'pear'}
assert set(json.loads(backups[0].read_text())['cards']) == {'apple'}
print('PASS legacy source retained and pre-restore local backup preserved')
PYCODE
fi
