#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
prompt = root / "prompts" / "ui-proof.md"
assert prompt.is_file(), prompt

for name, mode in {
    "dxproof": "manual proof mode",
    "dxcapture": "manual proof mode",
    "dxuicapture": "lifecycle decision mode",
}.items():
    skill = root / "skills" / name / "SKILL.md"
    text = skill.read_text(encoding="utf-8")
    match = re.search(r'^name:\s*["\']?([a-z0-9-]+)["\']?\s*$', text, re.M)
    assert match and match.group(1) == name, (name, match.group(1) if match else None)
    assert "prompts/ui-proof.md" in text, name
    assert mode in text.lower(), (name, mode)
    assert len(text.splitlines()) < 30, f"{name} duplicated the shared proof prompt"
PY

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ui-capture-test.XXXXXX")"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_DIR="$ROOT"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

SID="ui-capture-contract"
SESSION_DIR="$(dx_ui_capture_session_dir "$SID")"
STORYBOARD="$(dx_ui_capture_storyboard_file "$SID")"
EVIDENCE="$(dx_ui_capture_evidence_file "$SID")"

assert_eq "$SESSION_DIR/walkthrough.json" "$STORYBOARD" "storyboard path"
assert_eq "$SESSION_DIR/evidence.json" "$EVIDENCE" "evidence path"
assert_eq "30" "$(dx_ui_capture_retention_days)" "default retention"
assert_eq "MISSING" "$(dx_ui_capture_status "$SID")" "missing evidence status"

TOOLS_DIR="$(dx_ui_capture_tools_dir)"
mkdir -p "$TOOLS_DIR/node_modules/.bin" \
  "$TOOLS_DIR/node_modules/playwright" \
  "$TOOLS_DIR/node_modules/ffmpeg-static" \
  "$TOOLS_DIR/node_modules/kokoro-js"
printf '#!/usr/bin/env sh\n' > "$TOOLS_DIR/node_modules/.bin/playwright"
chmod +x "$TOOLS_DIR/node_modules/.bin/playwright"
printf '{"version":"%s"}\n' "$DX_UI_CAPTURE_PLAYWRIGHT_VERSION" > "$TOOLS_DIR/node_modules/playwright/package.json"
printf '{"version":"%s"}\n' "$DX_UI_CAPTURE_FFMPEG_STATIC_VERSION" > "$TOOLS_DIR/node_modules/ffmpeg-static/package.json"
printf 'module.exports = "ffmpeg";\n' > "$TOOLS_DIR/node_modules/ffmpeg-static/index.js"
printf '{"version":"%s"}\n' "$DX_UI_CAPTURE_KOKORO_VERSION" > "$TOOLS_DIR/node_modules/kokoro-js/package.json"
dx_ui_capture_playwright_ready || assert_at $LINENO
dx_ui_capture_media_ready || assert_at $LINENO
dx_ui_capture_narration_ready || assert_at $LINENO
dx_ui_capture_tooling_ready || assert_at $LINENO
printf '{"version":"0.0.0"}\n' > "$TOOLS_DIR/node_modules/kokoro-js/package.json"
assert_rejected "wrong narration package version" dx_ui_capture_narration_ready
printf '{"version":"%s"}\n' "$DX_UI_CAPTURE_KOKORO_VERSION" > "$TOOLS_DIR/node_modules/kokoro-js/package.json"

mkdir -p "$SESSION_DIR"
VALID_SCRIPT="$SESSION_DIR/walkthrough.json"
cat > "$VALID_SCRIPT" <<'JSON'
{
  "version": 1,
  "name": "settings-save",
  "title": "Save notification settings",
  "summary": "Shows the old settings flow and the new saved-state confirmation.",
  "product_context": "People need confirmation that notification settings were saved.",
  "technical_summary": "The form now persists and reports the successful request.",
  "how_to_test": "Open settings, enable email notifications, and save.",
  "suppress": ["[data-dex-transient-toast]"],
  "target_seconds": 70,
  "max_seconds": 90,
  "chapters": [
    {
      "stage": "before",
      "title": "Before",
      "narration": "Before this change, saving left the page without a clear confirmation.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}},
        {"action": "wait", "ms": 500},
        {"action": "waitFor", "locator": {"by": "testId", "name": "settings-form"}, "timeout_ms": 30000}
      ]
    },
    {
      "stage": "after",
      "title": "After",
      "narration": "Now the same flow confirms that settings were saved and remains ready for the next edit.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "scroll", "locator": {"by": "label", "name": "Email notifications"}},
        {"action": "click", "locator": {"by": "label", "name": "Email notifications"}},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}},
        {"action": "assert", "locator": {"by": "text", "name": "Settings saved"}}
      ]
    }
  ]
}
JSON

node "$ROOT/scripts/ui-capture.cjs" validate --script "$VALID_SCRIPT" > "$TMP_DIR/validate.out"
assert_contains 'storyboard: valid' "$TMP_DIR/validate.out"
assert_contains 'estimated_seconds:' "$TMP_DIR/validate.out"

python3 - "$VALID_SCRIPT" "$TMP_DIR/no-before.json" "$TMP_DIR/after-only.json" "$TMP_DIR/too-long.json" "$TMP_DIR/long-script.json" "$TMP_DIR/bad-action.json" "$TMP_DIR/fixed-wait-only.json" <<'PY'
import json
import sys

source, no_before, after_only, too_long, long_script, bad_action, fixed_wait_only = sys.argv[1:]
data = json.load(open(source, encoding="utf-8"))

value = dict(data)
value["chapters"] = [chapter for chapter in data["chapters"] if chapter["stage"] != "before"]
json.dump(value, open(no_before, "w", encoding="utf-8"))

value = json.loads(json.dumps(value))
value["comparison"] = "after_only"
value["baseline_reason"] = "The feature did not exist before this change."
json.dump(value, open(after_only, "w", encoding="utf-8"))

value = dict(data)
value["max_seconds"] = 91
json.dump(value, open(too_long, "w", encoding="utf-8"))

value = json.loads(json.dumps(data))
value["chapters"][1]["narration"] = " ".join(["x"] * 240)
json.dump(value, open(long_script, "w", encoding="utf-8"))

value = json.loads(json.dumps(data))
value["chapters"][1]["actions"][0]["action"] = "evaluate"
json.dump(value, open(bad_action, "w", encoding="utf-8"))

value = json.loads(json.dumps(data))
value["chapters"][0]["actions"] = [action for action in value["chapters"][0]["actions"] if action["action"] != "waitFor"]
json.dump(value, open(fixed_wait_only, "w", encoding="utf-8"))
PY

assert_rejected "missing before chapter" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/no-before.json"
node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/after-only.json" > "$TMP_DIR/after-only.out"
assert_contains 'storyboard: valid' "$TMP_DIR/after-only.out"
assert_rejected "duration over 90 seconds" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/too-long.json"
assert_rejected "narration over storyboard duration" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/long-script.json"
assert_rejected "arbitrary script action" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/bad-action.json"
assert_rejected "fixed wait is not a readiness gate" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/fixed-wait-only.json"
assert_rejected "missing script" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/missing.json"

node - "$ROOT/scripts/ui-capture.cjs" "$VALID_SCRIPT" "$TMP_DIR/producer" <<'JS'
const fs = require('fs');
const path = require('path');

const [modulePath, storyboardPath, producerRoot] = process.argv.slice(2);
const {
  generateNarration,
  loadStoryboard,
  narrationDurationMatches,
  produceBundle,
  runAction,
  stageHash,
  webUrl,
  writeVtt,
} = require(modulePath);
const storyboard = loadStoryboard(storyboardPath);
if (storyboard.chapters[0].actions.at(-1).locator.by !== 'testid') {
  throw new Error('common testId locator casing was not normalized');
}
if (webUrl('http://127.0.0.1:3000', 'test URL') !== 'http://127.0.0.1:3000/') {
  throw new Error('safe HTTP URL changed unexpectedly');
}
for (const unsafeUrl of ['file:///tmp/page.html', 'https://user:secret@example.test/']) {
  let rejected = false;
  try { webUrl(unsafeUrl, 'test URL'); } catch (_) { rejected = true; }
  if (!rejected) throw new Error(`unsafe URL accepted: ${unsafeUrl}`);
}

function addRecord(sessionDir, stage, hash) {
  const directory = path.join(sessionDir, `${stage}-capture`);
  fs.mkdirSync(directory, { recursive: true });
  const video = path.join(directory, `${stage}.webm`);
  const screenshot = path.join(directory, 'desktop.png');
  fs.writeFileSync(video, 'not real media');
  fs.writeFileSync(screenshot, 'not real image');
  fs.writeFileSync(path.join(directory, 'metadata.json'), `${JSON.stringify({
    stage,
    stageHash: hash,
    capturedAt: stage === 'before' ? '2026-01-01T00:00:00Z' : '2026-01-01T00:00:01Z',
    results: [{
      viewport: 'desktop',
      viewportSize: { width: 1440, height: 900 },
      videos: [video],
      screenshot,
      storyboardExecution: {
        actionCount: storyboard.chapters
          .filter((chapter) => chapter.stage === stage)
          .reduce((total, chapter) => total + chapter.actions.length, 0),
        readiness: [{
          chapterIndex: storyboard.chapters.findIndex((chapter) => chapter.stage === stage),
          action: 'waitFor',
          locator: { by: 'text', name: 'Loaded' },
          state: 'visible',
        }],
        readinessSatisfied: true,
        timeline: storyboard.chapters
          .map((chapter, chapterIndex) => ({ chapter, chapterIndex }))
          .filter(({ chapter }) => chapter.stage === stage)
          .map(({ chapterIndex }, index) => ({ chapterIndex, startSeconds: index * 4, endSeconds: (index + 1) * 4 })),
      },
    }],
  })}\n`);
}

(async () => {
  let waitedForOptions = null;
  const waitStartedAt = Date.now();
  await runAction({
    page: {
      getByText: () => ({
        waitFor: async (options) => {
          waitedForOptions = options;
          await new Promise((resolve) => setTimeout(resolve, 25));
        },
      }),
    },
    action: {
      action: 'waitFor',
      locator: { by: 'text', name: 'Loaded' },
      state: 'hidden',
      timeout_ms: 1234,
    },
    baseUrl: 'http://127.0.0.1/',
    screenshot: async () => {},
    stage: 'after',
  });
  if (Date.now() - waitStartedAt < 20 || waitedForOptions.state !== 'hidden' || waitedForOptions.timeout !== 1234) {
    throw new Error('waitFor did not await the requested readiness predicate');
  }

  if (narrationDurationMatches(24.15, 42)) throw new Error('truncated narration duration was accepted');
  const unsuppressed = JSON.parse(JSON.stringify(storyboard));
  unsuppressed.suppress = [];
  if (stageHash(unsuppressed, 'before') === stageHash(storyboard, 'before')) {
    throw new Error('suppression policy was not bound to the stage capture');
  }

  const narrationDir = path.join(producerRoot, 'narration');
  fs.mkdirSync(narrationDir, { recursive: true });
  const generatedTexts = [];
  const durations = new Map();
  const narrationServices = {
    createTts: async () => ({
      generate: async (text) => {
        generatedTexts.push(text);
        return {
          save: async (filePath) => {
            fs.writeFileSync(filePath, 'audio');
            durations.set(filePath, (text.trim().split(/\s+/u).length / 150) * 60);
          },
        };
      },
    }),
    durationOf: (filePath) => durations.get(filePath) || null,
    concatenate: (clips, output) => {
      fs.writeFileSync(output, 'combined audio');
      durations.set(output, clips.reduce((total, clip) => total + durations.get(clip), 0));
    },
  };
  let narration = await generateNarration(narrationDir, storyboard, 'ffmpeg', narrationServices);
  if (!narration.ok || generatedTexts.length !== storyboard.chapters.length) {
    throw new Error('narration was not generated once per chapter');
  }
  if (narration.reason !== null || narration.cues.length !== storyboard.chapters.length) {
    throw new Error('successful narration metadata is misleading');
  }

  const truncatedDir = path.join(producerRoot, 'truncated-narration');
  fs.mkdirSync(truncatedDir, { recursive: true });
  let generatedCount = 0;
  const truncatedDurations = new Map();
  narration = await generateNarration(truncatedDir, storyboard, 'ffmpeg', {
    createTts: async () => ({
      generate: async (text) => {
        generatedCount += 1;
        return {
          save: async (filePath) => {
            fs.writeFileSync(filePath, 'audio');
            const expected = (text.trim().split(/\s+/u).length / 150) * 60;
            truncatedDurations.set(filePath, generatedCount === 2 ? expected * 0.25 : expected);
          },
        };
      },
    }),
    durationOf: (filePath) => truncatedDurations.get(filePath) || null,
    concatenate: () => { throw new Error('truncated clips must not be concatenated'); },
  });
  if (narration.ok || !narration.incomplete || fs.existsSync(path.join(truncatedDir, 'narration.wav'))) {
    throw new Error('truncated narration was retained or accepted');
  }

  writeVtt(narrationDir, storyboard, [
    { chapterIndex: 0, startSeconds: 0, endSeconds: 3.25 },
    { chapterIndex: 1, startSeconds: 3.25, endSeconds: 9.5 },
  ]);
  const captions = fs.readFileSync(path.join(narrationDir, 'captions.vtt'), 'utf8');
  if (!captions.includes('00:00:03.250 --> 00:00:09.500')) {
    throw new Error('captions did not use measured chapter timing');
  }

  const fakeFfmpeg = path.join(producerRoot, 'fake-ffmpeg');
  fs.writeFileSync(fakeFfmpeg, [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'if [[ "$1" == "-i" && "$#" -eq 2 ]]; then',
    '  case "$2" in',
    '    *before.webm) duration="8.00" ;;',
    '    *after.webm) duration="9.00" ;;',
    '    *) duration="17.00" ;;',
    '  esac',
    '  printf "Duration: 00:00:%s\\n" "$duration" >&2',
    '  exit 1',
    'fi',
    'output="${!#}"',
    'printf "media\\n" > "$output"',
    '',
  ].join('\n'));
  fs.chmodSync(fakeFfmpeg, 0o700);
  const readyDir = path.join(producerRoot, 'ready');
  addRecord(readyDir, 'before', stageHash(storyboard, 'before'));
  addRecord(readyDir, 'after', stageHash(storyboard, 'after'));
  process.env.DX_UI_CAPTURE_FFMPEG = fakeFfmpeg;
  let result = await produceBundle(readyDir, storyboard, false);
  if (result.status !== 'READY' || !result.readiness_verified || result.narration !== 'captions-only') {
    throw new Error('verified captions-only bundle was not ready');
  }
  const measuredCaptions = fs.readFileSync(path.join(readyDir, 'captions.vtt'), 'utf8');
  if (!measuredCaptions.includes('00:00:08.000 --> 00:00:12.000')) {
    throw new Error('captions-only bundle did not use the capture timeline');
  }
  if (result.suppressed_selectors[0] !== '[data-dex-transient-toast]') {
    throw new Error('suppressed selectors were not recorded in the bundle');
  }

  const mismatchedDir = path.join(producerRoot, 'mismatched-viewports');
  addRecord(mismatchedDir, 'before', stageHash(storyboard, 'before'));
  addRecord(mismatchedDir, 'after', stageHash(storyboard, 'after'));
  const beforeMetadataPath = path.join(mismatchedDir, 'before-capture', 'metadata.json');
  const beforeMetadata = JSON.parse(fs.readFileSync(beforeMetadataPath, 'utf8'));
  beforeMetadata.results.push({
    ...JSON.parse(JSON.stringify(beforeMetadata.results[0])),
    viewport: 'mobile',
    viewportSize: { width: 390, height: 844 },
  });
  fs.writeFileSync(beforeMetadataPath, `${JSON.stringify(beforeMetadata)}\n`);
  result = await produceBundle(mismatchedDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || result.viewport_parity !== false
    || !result.message.includes('viewport sets differ')) {
    throw new Error('mismatched before and after viewports were accepted');
  }

  const staleDir = path.join(producerRoot, 'stale');
  addRecord(staleDir, 'before', 'stale-before');
  addRecord(staleDir, 'after', 'stale-after');
  result = await produceBundle(staleDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || result.video) throw new Error('stale captures were accepted');
  const transcript = fs.readFileSync(path.join(staleDir, 'transcript.md'), 'utf8');
  if (transcript.includes('### Before: Before') || transcript.includes('### After: After')) {
    throw new Error('transcript duplicated stage labels');
  }
  if (!transcript.includes('### Before\n') || !transcript.includes('### After\n')) {
    throw new Error('transcript stage headings are missing');
  }

  const failedDir = path.join(producerRoot, 'failed');
  addRecord(failedDir, 'before', stageHash(storyboard, 'before'));
  addRecord(failedDir, 'after', stageHash(storyboard, 'after'));
  process.env.DX_UI_CAPTURE_FFMPEG = '/usr/bin/false';
  result = await produceBundle(failedDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || result.video) throw new Error('production failure was accepted');
  if (!result.message.includes('production failed')) throw new Error('production failure was not explained');
  if (!fs.existsSync(path.join(failedDir, 'bundle.json'))) throw new Error('failure bundle missing');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

REAL_NODE=$(command -v node)
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/node" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == "validate" && "${1:-}" == */scripts/ui-capture.cjs ]]; then
  printf '%s\n' 'storyboard: valid' 'estimated_seconds: 10' 'max_seconds: 90'
  exit 0
fi
if [[ "${2:-}" == "capture" && "${1:-}" == */scripts/ui-capture.cjs ]]; then
  printf '%s\n' 'fixture capture failed' >&2
  exit 17
fi
exec "$REAL_NODE" "$@"
SH
chmod +x "$FAKE_BIN/node"

FAILURE_SID="ui-capture-failure"
set +e
PATH="$FAKE_BIN:$PATH" REAL_NODE="$REAL_NODE" bash "$ROOT/bin/ui-capture.sh" capture \
  --session "$FAILURE_SID" --stage before --script "$VALID_SCRIPT" \
  --url "http://127.0.0.1:49999" > "$TMP_DIR/capture-failure.out" 2>&1
failure_exit=$?
set -e
assert_eq "17" "$failure_exit" "capture failure exit"
assert_eq "NEEDS_REVIEW" "$(dx_ui_capture_status "$FAILURE_SID")" "capture failure status"
assert_contains 'before capture failed' "$(dx_ui_capture_evidence_file "$FAILURE_SID")"
assert_contains 'fixture capture failed' "$(dx_ui_capture_session_dir "$FAILURE_SID")/before-capture-error.log"
assert_contains 'UI proof: NEEDS_REVIEW' "$TMP_DIR/capture-failure.out"

MANIFEST="$SESSION_DIR/visual-evidence.md"
VIDEO="$SESSION_DIR/walkthrough.mp4"
printf '# evidence\n' > "$MANIFEST"
printf 'video\n' > "$VIDEO"
printf 'WEBVTT\n' > "$SESSION_DIR/captions.vtt"
dx_ui_capture_write_status "$SID" "READY" "Walkthrough ready" "$MANIFEST" "$VIDEO"
assert_eq "READY" "$(dx_ui_capture_status "$SID")" "ready evidence status"
assert_file "$EVIDENCE"
assert_contains '"status": "READY"' "$EVIDENCE"

dx_ui_capture_summary "$SID" > "$TMP_DIR/summary.out"
assert_contains 'UI proof: READY' "$TMP_DIR/summary.out"
assert_contains "$VIDEO" "$TMP_DIR/summary.out"
assert_contains "$EVIDENCE" "$TMP_DIR/summary.out"

RUN_ID=$(dx_run_prepare "$SID" "$ROOT" "worktree" "ui-capture-contract" "UI proof test" "test")
dx_ui_capture_register_bundle "$SID"
assert_file "$(dx_run_artifact_file "$RUN_ID" "ui-proof/walkthrough.mp4")"
assert_file "$(dx_run_artifact_file "$RUN_ID" "ui-proof/walkthrough.json")"
assert_file "$(dx_run_artifact_file "$RUN_ID" "ui-proof/evidence.json")"
assert_contains '"type": "ui_walkthrough"' "$(dx_run_artifact_manifest_file "$RUN_ID")"
python3 - "$(dx_run_artifact_manifest_file "$RUN_ID")" "$SID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    artifacts = json.load(manifest_file)["artifacts"]
walkthrough = next(item for item in artifacts if item["type"] == "ui_walkthrough")
assert walkthrough["metadata"] == {
    "producer": "dex_ui_capture",
    "role": "walkthrough",
    "session_id": sys.argv[2],
    "temporary": True,
}, walkthrough
captions = next(item for item in artifacts if item["type"] == "ui_captions")
assert captions["metadata"]["role"] == "captions", captions
PY

dx_ui_capture_mark_completed "$SID"
assert_contains '"phase_state": "completed"' "$EVIDENCE"
assert_contains '"completed_epoch":' "$EVIDENCE"

bash "$ROOT/bin/ui-capture.sh" show --session "$SID" --json > "$TMP_DIR/show.json"
assert_contains '"status": "READY"' "$TMP_DIR/show.json"
bash "$ROOT/bin/ui-capture.sh" show --session "$SID" > "$TMP_DIR/show.out"
assert_contains 'UI proof: READY' "$TMP_DIR/show.out"

dx_ui_capture_write_status "$SID" "NEEDS_REVIEW" "Narration unavailable; captions retained" "$MANIFEST" "$VIDEO"
assert_eq "NEEDS_REVIEW" "$(dx_ui_capture_status "$SID")" "degraded evidence status"
assert_rejected "invalid status" dx_ui_capture_write_status "$SID" "COMPLETE" "bad" "$MANIFEST" "$VIDEO"

CUSTOM_SID="ui-capture-custom"
printf '# Custom visual proof\n' > "$TMP_DIR/custom-manifest.md"
printf 'custom video\n' > "$TMP_DIR/custom-video.mp4"
printf 'custom poster\n' > "$TMP_DIR/custom-poster.png"
bash "$ROOT/bin/ui-capture.sh" ready --session "$CUSTOM_SID" \
  --manifest "$TMP_DIR/custom-manifest.md" \
  --video-file "$TMP_DIR/custom-video.mp4" \
  --poster-file "$TMP_DIR/custom-poster.png" \
  --reason "The project already has a purpose-built browser recorder." > "$TMP_DIR/custom.out"
assert_eq "READY" "$(dx_ui_capture_status "$CUSTOM_SID")" "custom evidence status"
assert_file "$(dx_ui_capture_manifest_file "$CUSTOM_SID")"
assert_file "$(dx_ui_capture_session_dir "$CUSTOM_SID")/walkthrough.mp4"
assert_file "$(dx_ui_capture_session_dir "$CUSTOM_SID")/poster.png"
assert_contains 'purpose-built browser recorder' "$(dx_ui_capture_evidence_file "$CUSTOM_SID")"

SKIPPED_SID="ui-capture-skipped"
bash "$ROOT/bin/ui-capture.sh" skip --session "$SKIPPED_SID" --reason "The visible change is a one-word label and the focused browser smoke test is clearer than a video." > "$TMP_DIR/skip.out"
assert_eq "SKIPPED" "$(dx_ui_capture_status "$SKIPPED_SID")" "agent-skipped status"
assert_contains 'UI proof: SKIPPED' "$TMP_DIR/skip.out"
assert_contains 'one-word label' "$(dx_ui_capture_evidence_file "$SKIPPED_SID")"
assert_rejected "skip without reason" bash "$ROOT/bin/ui-capture.sh" skip --session "skip-no-reason"

N_A_SID="ui-capture-na"
bash "$ROOT/bin/ui-capture.sh" not-applicable --session "$N_A_SID" --reason "No browser UI changes" > "$TMP_DIR/na.out"
assert_eq "N/A" "$(dx_ui_capture_status "$N_A_SID")" "not-applicable status"
assert_contains 'UI proof: N/A' "$TMP_DIR/na.out"

OLD_SID="ui-capture-old"
OLD_DIR="$(dx_ui_capture_session_dir "$OLD_SID")"
mkdir -p "$OLD_DIR"
printf 'old\n' > "$OLD_DIR/walkthrough.mp4"
dx_ui_capture_write_status "$OLD_SID" "READY" "Old completed proof" "$OLD_DIR/visual-evidence.md" "$OLD_DIR/walkthrough.mp4" "completed" "1"

ACTIVE_SID="ui-capture-active"
ACTIVE_DIR="$(dx_ui_capture_session_dir "$ACTIVE_SID")"
mkdir -p "$ACTIVE_DIR"
dx_ui_capture_write_status "$ACTIVE_SID" "READY" "Active proof" "$ACTIVE_DIR/visual-evidence.md" "$ACTIVE_DIR/walkthrough.mp4" "active" "1"

OUTSIDE_DIR="$TMP_DIR/outside-proof"
mkdir -p "$OUTSIDE_DIR"
printf 'keep\n' > "$OUTSIDE_DIR/keep.txt"
ln -s "$OUTSIDE_DIR" "$(dx_artifacts_dir)/ui/ui-capture-symlink"

dx_ui_capture_cleanup 30 > "$TMP_DIR/cleanup.out"
assert_no_file "$OLD_DIR"
[[ -d "$ACTIVE_DIR" ]] || assert_at $LINENO
assert_file "$OUTSIDE_DIR/keep.txt"
assert_contains 'Removed 1 expired UI proof bundle' "$TMP_DIR/cleanup.out"

printf 'ui capture tests passed\n'
