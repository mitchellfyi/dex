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

GH_BIN="$TMP_DIR/gh-bin"
mkdir -p "$GH_BIN"
cat > "$GH_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "pr edit --help" ]]; then
  printf '%s\n' '      --attach file   Attach an image or video file'
  # Write past the pipe buffer so a reader that exits at --attach breaks gh.
  for ((help_line=0; help_line<1024; help_line++)); do
    printf '%4096s\n' ''
  done
  exit 0
fi
exit 1
SH
chmod +x "$GH_BIN/gh"
PATH="$GH_BIN:$PATH" dx_github_pr_attachments_supported || assert_at $LINENO
cat > "$GH_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "pr edit --help" ]]; then
  printf '%s\n' '      --body text   Set the new body'
  exit 0
fi
exit 1
SH
chmod +x "$GH_BIN/gh"
assert_rejected "GitHub CLI without --attach" env PATH="$GH_BIN:$PATH" bash -c \
  'set -euo pipefail; source "$DEX_DIR/lib/common.sh"; dx_github_pr_attachments_supported'

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

# Assertions carry deterministic predicates and point at acceptance criteria.
python3 - "$VALID_SCRIPT" "$TMP_DIR/predicates.json" "$TMP_DIR/text-without-expected.json" "$TMP_DIR/criterion-zero.json" "$TMP_DIR/unknown-predicate.json" "$TMP_DIR/identical-without-reason.json" "$TMP_DIR/bad-pattern.json" <<'PY'
import json
import sys

source, predicates, text_without_expected, criterion_zero, unknown_predicate, identical_without_reason, bad_pattern = sys.argv[1:]
data = json.load(open(source, encoding="utf-8"))


def variant():
    return json.loads(json.dumps(data))


value = variant()
value["chapters"][1]["actions"][-1].update({"predicate": "text_equals", "expected": "Settings saved", "criterion": 1})
value["chapters"][1]["actions"].append({"action": "assert", "predicate": "url_matches", "pattern": "/settings(\\?saved=1)?$", "criterion": 2})
value["chapters"][1]["actions"].append({"action": "assert", "locator": {"by": "role", "role": "listitem", "name": "Preference"}, "predicate": "count", "count": 3})
value["chapters"][1]["actions"].append({"action": "assert", "locator": {"by": "label", "name": "Email notifications"}, "predicate": "attribute", "attribute": "aria-checked", "expected": "true", "timeout_ms": 2000})
json.dump(value, open(predicates, "w", encoding="utf-8"))

value = variant()
value["chapters"][1]["actions"][-1]["predicate"] = "text_equals"
json.dump(value, open(text_without_expected, "w", encoding="utf-8"))

value = variant()
value["chapters"][1]["actions"][-1]["criterion"] = 0
json.dump(value, open(criterion_zero, "w", encoding="utf-8"))

value = variant()
value["chapters"][1]["actions"][-1]["predicate"] = "glows"
json.dump(value, open(unknown_predicate, "w", encoding="utf-8"))

value = variant()
value["expect_identical"] = True
json.dump(value, open(identical_without_reason, "w", encoding="utf-8"))

value = variant()
value["chapters"][1]["actions"].append({"action": "assert", "predicate": "url_matches", "pattern": "("})
json.dump(value, open(bad_pattern, "w", encoding="utf-8"))
PY

node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/predicates.json" > "$TMP_DIR/predicates.out"
assert_contains 'storyboard: valid' "$TMP_DIR/predicates.out"
assert_rejected "text predicate without expected" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/text-without-expected.json"
assert_rejected "criterion below 1" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/criterion-zero.json"
assert_rejected "unknown predicate" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/unknown-predicate.json"
assert_rejected "expect_identical without a reason" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/identical-without-reason.json"
assert_rejected "url pattern that does not compile" node "$ROOT/scripts/ui-capture.cjs" validate --script "$TMP_DIR/bad-pattern.json"

node - "$ROOT/scripts/ui-capture.cjs" "$VALID_SCRIPT" "$TMP_DIR/producer" <<'JS'
const fs = require('fs');
const path = require('path');

const [modulePath, storyboardPath, producerRoot] = process.argv.slice(2);
const {
  buildContactSheet,
  evaluateAssertion,
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

function addRecord(sessionDir, stage, hash, extra = {}) {
  const directory = path.join(sessionDir, `${stage}-capture`);
  fs.mkdirSync(directory, { recursive: true });
  const video = path.join(directory, `${stage}.webm`);
  const screenshot = path.join(directory, 'desktop.png');
  fs.writeFileSync(video, 'not real media');
  fs.writeFileSync(screenshot, extra.screenshotBytes || `${stage} image`);
  fs.writeFileSync(path.join(directory, 'metadata.json'), `${JSON.stringify({
    stage,
    stageHash: hash,
    capturedAt: stage === 'before' ? '2026-01-01T00:00:00Z' : '2026-01-01T00:00:01Z',
    results: [{
      viewport: 'desktop',
      viewportSize: { width: 1440, height: 900 },
      videos: [video],
      screenshot,
      cleanScreenshotHash: extra.cleanScreenshotHash,
      storyboardExecution: {
        actionCount: storyboard.chapters
          .filter((chapter) => chapter.stage === stage)
          .reduce((total, chapter) => total + chapter.actions.length, 0),
        readiness: extra.readiness || [{
          chapterIndex: storyboard.chapters.findIndex((chapter) => chapter.stage === stage),
          action: 'waitFor',
          locator: { by: 'text', name: 'Loaded' },
          state: 'visible',
          satisfied: true,
        }],
        readinessSatisfied: extra.readinessSatisfied === undefined ? true : extra.readinessSatisfied,
        assertions: extra.assertions || [],
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

  // An assertion is satisfied only once two consecutive samples agree, so a
  // page still settling cannot pass on its first lucky frame.
  const settlingTexts = ['Saving\u2026', 'Saved', 'Saved'];
  const settling = await evaluateAssertion({
    page: { getByText: () => ({ count: async () => 1, innerText: async () => settlingTexts.shift() || 'Saved' }) },
    action: { action: 'assert', predicate: 'text_equals', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, criterion: 3, timeout_ms: 2000 },
    sampleIntervalMs: 5,
  });
  if (settling.outcome !== 'satisfied' || settling.samples < 3 || settling.criterion !== 3 || settling.observed !== 'Saved') {
    throw new Error(`settling text was not accepted after it stabilized: ${JSON.stringify(settling)}`);
  }
  const mismatch = await evaluateAssertion({
    page: { getByText: () => ({ count: async () => 1, innerText: async () => '  x  ' }) },
    action: { action: 'assert', predicate: 'text_equals', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, timeout_ms: 60 },
    sampleIntervalMs: 10,
  });
  if (mismatch.outcome !== 'unsatisfied' || mismatch.observed !== 'x' || mismatch.expected !== 'Saved' || mismatch.predicate !== 'text_equals') {
    throw new Error(`mismatched text was not recorded as unsatisfied: ${JSON.stringify(mismatch)}`);
  }
  const thrown = await evaluateAssertion({
    page: { getByText: () => ({ count: async () => 2, innerText: async () => { throw new Error('strict mode violation: 2 elements'); } }) },
    action: { action: 'assert', predicate: 'text_contains', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, timeout_ms: 60 },
    sampleIntervalMs: 10,
  });
  if (thrown.outcome !== 'unknown' || !String(thrown.observed).includes('strict mode')) {
    throw new Error(`a throwing observation was not recorded as unknown: ${JSON.stringify(thrown)}`);
  }
  const counted = await evaluateAssertion({
    page: { getByRole: () => ({ count: async () => 3 }) },
    action: { action: 'assert', predicate: 'count', count: 3, locator: { by: 'role', role: 'listitem', name: 'Preference' }, timeout_ms: 500 },
    sampleIntervalMs: 5,
  });
  if (counted.outcome !== 'satisfied' || counted.observed !== 3) throw new Error(`count predicate failed: ${JSON.stringify(counted)}`);
  const located = await evaluateAssertion({
    page: { url: () => 'http://127.0.0.1:3000/settings?saved=1' },
    action: { action: 'assert', predicate: 'url_matches', pattern: '/settings(\\?saved=1)?$', timeout_ms: 500 },
    sampleIntervalMs: 5,
  });
  if (located.outcome !== 'satisfied' || located.observed !== 'http://127.0.0.1:3000/settings?saved=1') {
    throw new Error(`url_matches predicate failed: ${JSON.stringify(located)}`);
  }
  const hiddenState = await evaluateAssertion({
    page: { getByText: () => ({ isVisible: async () => false }) },
    action: { action: 'assert', predicate: 'hidden', locator: { by: 'text', name: 'Spinner' }, timeout_ms: 500 },
    sampleIntervalMs: 5,
  });
  if (hiddenState.outcome !== 'satisfied' || hiddenState.observed !== false) throw new Error(`hidden predicate failed: ${JSON.stringify(hiddenState)}`);

  // An element that is not on the page is a claim that did not hold, found
  // within the author's timeout, not a 30 s tooling failure.
  const absentStartedAt = Date.now();
  const absent = await evaluateAssertion({
    page: { getByText: () => ({ count: async () => 0, innerText: async () => { throw new Error('innerText must not run on an absent element'); } }) },
    action: { action: 'assert', predicate: 'text_equals', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, timeout_ms: 300 },
    sampleIntervalMs: 20,
  });
  if (absent.outcome !== 'unsatisfied' || absent.observed !== null || Date.now() - absentStartedAt > 2000) {
    throw new Error(`an absent element was not recorded as unsatisfied in time: ${JSON.stringify(absent)}`);
  }
  const getterTimeouts = [];
  const bounded = await evaluateAssertion({
    page: { getByText: () => ({ count: async () => 1, innerText: async (options) => { getterTimeouts.push(options && options.timeout); return 'Saved'; } }) },
    action: { action: 'assert', predicate: 'text_equals', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, timeout_ms: 500 },
    sampleIntervalMs: 5,
  });
  if (bounded.outcome !== 'satisfied' || getterTimeouts.length < 2 || !getterTimeouts.every((value) => Number.isInteger(value) && value > 0 && value <= 500)) {
    throw new Error(`getter waits are not bounded by timeout_ms: ${JSON.stringify(getterTimeouts)}`);
  }

  // A failed claim is evidence, not a crash: the stage keeps recording and the
  // bundle reports the predicate that did not hold. Nothing is pointed at when
  // the claim did not hold, so a missing element cannot freeze the footage.
  const scrolled = [];
  const pointable = {
    count: async () => 1,
    innerText: async () => 'x',
    isVisible: async () => true,
    scrollIntoViewIfNeeded: async (options) => { scrolled.push(options); },
    boundingBox: async () => ({ x: 10, y: 10, width: 100, height: 20 }),
    evaluate: async () => ({}),
  };
  const unsatisfiedRun = await runAction({
    page: {
      evaluate: async () => false,
      waitForTimeout: async () => {},
      mouse: { move: async () => {} },
      getByText: () => pointable,
    },
    action: { action: 'assert', predicate: 'text_equals', expected: 'Saved', locator: { by: 'text', name: 'Saved' }, timeout_ms: 30 },
    baseUrl: 'http://127.0.0.1/',
    screenshot: async () => {},
    stage: 'after',
  });
  if (!unsatisfiedRun || unsatisfiedRun.outcome !== 'unsatisfied' || unsatisfiedRun.observed !== 'x') {
    throw new Error(`an unsatisfied assert threw or returned nothing: ${JSON.stringify(unsatisfiedRun)}`);
  }
  if (scrolled.length !== 0) throw new Error('an unsatisfied assert still tried to point at its element');
  const satisfiedRun = await runAction({
    page: {
      evaluate: async () => false,
      waitForTimeout: async () => {},
      mouse: { move: async () => {} },
      getByText: () => pointable,
    },
    action: { action: 'assert', predicate: 'visible', locator: { by: 'text', name: 'Saved' }, timeout_ms: 500 },
    baseUrl: 'http://127.0.0.1/',
    screenshot: async () => {},
    stage: 'after',
  });
  if (satisfiedRun.outcome !== 'satisfied' || scrolled.length !== 1 || !scrolled[0] || scrolled[0].timeout !== 750) {
    throw new Error(`a satisfied assert did not point at its element with a bounded wait: ${JSON.stringify(scrolled)}`);
  }
  const urlRun = await runAction({
    page: { evaluate: async () => false, url: () => 'http://127.0.0.1/settings' },
    action: { action: 'assert', predicate: 'url_matches', pattern: '/settings$', timeout_ms: 500 },
    baseUrl: 'http://127.0.0.1/',
    screenshot: async () => {},
    stage: 'after',
  });
  if (!urlRun || urlRun.outcome !== 'satisfied') throw new Error(`a locator-free url_matches assert failed: ${JSON.stringify(urlRun)}`);

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
    'case "$*" in *showinfo*)',
    '  for n in $(seq 1 12); do printf "[Parsed_showinfo_1 @ 0x1] n: %d pts: %d pts_time:0\\n" "$n" "$n" >&2; done',
    '  exit 0 ;;',
    'esac',
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
  const claim = (outcome, observed) => ({
    chapterIndex: 1, actionIndex: 4, predicate: 'text_equals', expected: 'Settings saved', observed, outcome, samples: 2, elapsedMs: 300, criterion: 1,
  });
  const criteriaFile = path.join(producerRoot, 'review-criteria.json');
  fs.writeFileSync(criteriaFile, `${JSON.stringify({
    version: 1,
    source: 'approved-plan',
    objectives: ['Confirm saves'],
    acceptance_criteria: ['Saving confirms the change'],
    verification_requirements: ['The settings tests pass'],
  })}\n`);
  const readyDir = path.join(producerRoot, 'ready');
  addRecord(readyDir, 'before', stageHash(storyboard, 'before'), { assertions: [claim('unsatisfied', 'Settings')] });
  addRecord(readyDir, 'after', stageHash(storyboard, 'after'), { assertions: [claim('satisfied', 'Settings saved')] });
  const nestedBefore = path.join(readyDir, 'before-capture', 'steps');
  fs.mkdirSync(nestedBefore, { recursive: true });
  fs.writeFileSync(path.join(nestedBefore, 'confirmation.jpg'), 'nested image');
  fs.writeFileSync(path.join(nestedBefore, 'browser.log'), 'not public media');
  fs.writeFileSync(path.join(readyDir, 'after-capture', 'mobile.mov'), 'nested video');
  fs.symlinkSync(path.join(readyDir, 'before-capture', 'desktop.png'), path.join(nestedBefore, 'linked.png'));
  const outsideMediaDir = path.join(producerRoot, 'outside-media');
  fs.mkdirSync(outsideMediaDir, { recursive: true });
  fs.writeFileSync(path.join(outsideMediaDir, 'leak.png'), 'outside image');
  fs.symlinkSync(outsideMediaDir, path.join(nestedBefore, 'outside'));
  const readyBeforeMetadataPath = path.join(readyDir, 'before-capture', 'metadata.json');
  const readyBeforeMetadata = JSON.parse(fs.readFileSync(readyBeforeMetadataPath, 'utf8'));
  readyBeforeMetadata.results[0].videos.push(path.join(nestedBefore, 'outside', 'leak.png'));
  fs.writeFileSync(readyBeforeMetadataPath, `${JSON.stringify(readyBeforeMetadata)}\n`);
  const staleMediaDir = path.join(readyDir, 'stale-capture');
  fs.mkdirSync(staleMediaDir, { recursive: true });
  fs.writeFileSync(path.join(staleMediaDir, 'stale.png'), 'stale image');
  process.env.DX_UI_CAPTURE_FFMPEG = fakeFfmpeg;
  let result = await produceBundle(readyDir, storyboard, false, { criteriaFile });
  if (result.status !== 'READY' || !result.readiness_verified || result.narration !== 'captions-only') {
    throw new Error(`verified captions-only bundle was not ready: ${result.message}`);
  }
  // The claims the stages recorded become a criteria table a reviewer can read.
  if (!result.assertions || result.assertions.after.length !== 1 || result.assertions.after[0].outcome !== 'satisfied'
    || result.assertions.before[0].outcome !== 'unsatisfied') {
    throw new Error(`stage assertions were not carried into the bundle: ${JSON.stringify(result.assertions)}`);
  }
  const expectedCriteria = [{ index: 1, text: 'Saving confirms the change', before: 'unsatisfied', after: 'satisfied' }];
  if (JSON.stringify(result.criteria) !== JSON.stringify(expectedCriteria)) {
    throw new Error(`criteria table is wrong: ${JSON.stringify(result.criteria)}`);
  }
  const readyManifest = fs.readFileSync(path.join(readyDir, 'visual-evidence.md'), 'utf8');
  if (!readyManifest.includes('## Acceptance criteria') || !readyManifest.includes('| 1 | Saving confirms the change | unsatisfied | satisfied |')) {
    throw new Error('manifest lacks the acceptance criteria table');
  }
  // The keyframe contact sheet is the record a reader can actually look at.
  const contactSheet = path.join(readyDir, 'contact.png');
  if (result.contact_sheet !== contactSheet || !fs.existsSync(contactSheet) || !['scene', 'uniform'].includes(result.contact_sheet_mode)) {
    throw new Error(`contact sheet was not produced: ${JSON.stringify([result.contact_sheet, result.contact_sheet_mode])}`);
  }
  if (!readyManifest.includes(`- Contact sheet: ${contactSheet}`)) throw new Error('manifest does not list the contact sheet');
  const contactAttachment = result.attachments.find((attachment) => attachment.stage === 'contact');
  if (!contactAttachment || contactAttachment.alt !== 'Save notification settings keyframe contact sheet') {
    throw new Error(`contact sheet attachment is missing or mislabelled: ${JSON.stringify(contactAttachment)}`);
  }
  const noSceneFfmpeg = path.join(producerRoot, 'fake-ffmpeg-no-scene');
  fs.writeFileSync(noSceneFfmpeg, [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'case "$*" in *showinfo*) printf "[Parsed_showinfo_1 @ 0x1] n: 0 pts: 0 pts_time:0\\n" >&2; exit 0 ;; esac',
    'output="${!#}"',
    'printf "media\\n" > "$output"',
    '',
  ].join('\n'));
  fs.chmodSync(noSceneFfmpeg, 0o700);
  const fallbackSheet = path.join(producerRoot, 'fallback-contact.png');
  const fallback = buildContactSheet(noSceneFfmpeg, path.join(readyDir, 'walkthrough.mp4'), fallbackSheet, { durationSeconds: 17 });
  if (fallback.mode !== 'uniform' || fallback.path !== fallbackSheet || !fs.existsSync(fallbackSheet) || fallback.frames !== 1) {
    throw new Error(`contact sheet did not fall back to uniform sampling: ${JSON.stringify(fallback)}`);
  }
  if (result.contact_sheet_mode !== 'scene' || result.contact_sheet_frames !== 12) {
    throw new Error(`twelve scene frames should select scene mode: ${JSON.stringify([result.contact_sheet_mode, result.contact_sheet_frames])}`);
  }
  const measuredCaptions = fs.readFileSync(path.join(readyDir, 'captions.vtt'), 'utf8');
  if (!measuredCaptions.includes('00:00:08.000 --> 00:00:12.000')) {
    throw new Error('captions-only bundle did not use the capture timeline');
  }
  if (result.suppressed_selectors[0] !== '[data-dex-transient-toast]') {
    throw new Error('suppressed selectors were not recorded in the bundle');
  }
  const attachmentPaths = result.attachments.map((attachment) => attachment.path);
  const expectedAttachments = [
    path.join(readyDir, 'walkthrough.mp4'),
    path.join(readyDir, 'poster.png'),
    path.join(readyDir, 'contact.png'),
    path.join(readyDir, 'before-capture', 'desktop.png'),
    path.join(readyDir, 'before-capture', 'before.webm'),
    path.join(nestedBefore, 'confirmation.jpg'),
    path.join(readyDir, 'after-capture', 'desktop.png'),
    path.join(readyDir, 'after-capture', 'after.webm'),
    path.join(readyDir, 'after-capture', 'mobile.mov'),
  ];
  if (JSON.stringify(attachmentPaths) !== JSON.stringify(expectedAttachments)) {
    throw new Error(`PR attachment inventory is incomplete or unstable: ${JSON.stringify(attachmentPaths)}`);
  }
  if (!/^[0-9a-f]{64}$/u.test(result.attachment_fingerprint)) {
    throw new Error('PR attachment fingerprint is missing or malformed');
  }
  if (result.attachments.some((attachment) => attachment.path.endsWith('linked.png')
    || attachment.path.endsWith('browser.log') || attachment.path.endsWith('stale.png')
    || attachment.path.endsWith('leak.png'))) {
    throw new Error('unsafe, unsupported, or stale media entered the PR attachment inventory');
  }
  if (result.attachments.find((attachment) => attachment.path.endsWith('confirmation.jpg')).alt
    !== 'Save notification settings before confirmation') {
    throw new Error('image attachment alt text does not describe its proof stage');
  }
  if (result.attachments.find((attachment) => attachment.path.endsWith('poster.png')).alt
    !== 'Save notification settings walkthrough poster') {
    throw new Error('poster attachment alt text is repetitive or unclear');
  }
  const initialAttachmentFingerprint = result.attachment_fingerprint;
  result = await produceBundle(readyDir, storyboard, false);
  if (result.attachment_fingerprint !== initialAttachmentFingerprint) {
    throw new Error('unchanged PR attachments produced an unstable fingerprint');
  }
  fs.appendFileSync(path.join(nestedBefore, 'confirmation.jpg'), ' changed');
  result = await produceBundle(readyDir, storyboard, false);
  if (result.attachment_fingerprint === initialAttachmentFingerprint) {
    throw new Error('changed PR attachment content did not update the fingerprint');
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
  // A claim that did not hold in the after stage is a finding, not a pass.
  const unsatisfiedDir = path.join(producerRoot, 'unsatisfied');
  addRecord(unsatisfiedDir, 'before', stageHash(storyboard, 'before'));
  addRecord(unsatisfiedDir, 'after', stageHash(storyboard, 'after'), { assertions: [claim('unsatisfied', 'Saving\u2026')] });
  process.env.DX_UI_CAPTURE_FFMPEG = fakeFfmpeg;
  result = await produceBundle(unsatisfiedDir, storyboard, false, { criteriaFile });
  if (result.status !== 'NEEDS_REVIEW' || !result.message.includes('text_equals') || !result.message.includes('expected')) {
    throw new Error(`an unsatisfied after-stage claim was accepted: ${result.status} ${result.message}`);
  }
  if (!result.criteria || result.criteria[0].after !== 'unsatisfied') throw new Error('criteria table hid the failed claim');

  // A stage whose final gate is an assert that did not hold is reported as
  // that, not as a missing readiness gate.
  const unsettledDir = path.join(producerRoot, 'unsettled');
  addRecord(unsettledDir, 'before', stageHash(storyboard, 'before'));
  addRecord(unsettledDir, 'after', stageHash(storyboard, 'after'), {
    assertions: [claim('unsatisfied', 'Saving\u2026')],
    readiness: [{ chapterIndex: 1, action: 'assert', locator: { by: 'text', name: 'Settings saved' }, state: 'text_equals', satisfied: false }],
    readinessSatisfied: false,
  });
  result = await produceBundle(unsettledDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || !result.message.includes('final claim did not hold') || result.message.includes('Re-run both stages')) {
    throw new Error(`an unsettled final assert was misreported: ${result.message}`);
  }

  // Proof must prove: an after state identical to before shows no change.
  const identicalDir = path.join(producerRoot, 'identical');
  addRecord(identicalDir, 'before', stageHash(storyboard, 'before'), { screenshotBytes: 'same image' });
  addRecord(identicalDir, 'after', stageHash(storyboard, 'after'), { screenshotBytes: 'same image' });
  result = await produceBundle(identicalDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || !result.message.includes('identical')) {
    throw new Error(`identical before and after was accepted: ${result.status} ${result.message}`);
  }
  // The stage badge and caption live inside the page, so the visible
  // screenshots always differ between stages; the parity check hashes a shot
  // taken with the overlay hidden, which the record carries as a hash.
  const badgedDir = path.join(producerRoot, 'badged-identical');
  addRecord(badgedDir, 'before', stageHash(storyboard, 'before'), { screenshotBytes: 'BEFORE badge over the same page', cleanScreenshotHash: 'a'.repeat(64) });
  addRecord(badgedDir, 'after', stageHash(storyboard, 'after'), { screenshotBytes: 'AFTER badge over the same page', cleanScreenshotHash: 'a'.repeat(64) });
  result = await produceBundle(badgedDir, storyboard, false);
  if (result.status !== 'NEEDS_REVIEW' || !result.message.includes('identical') || result.screenshot_parity !== 'identical') {
    throw new Error(`identical pages under different badges were accepted: ${result.status} ${result.message}`);
  }
  const declaredIdentical = JSON.parse(JSON.stringify(storyboard));
  declaredIdentical.expect_identical = true;
  declaredIdentical.identical_reason = 'The change only alters the request payload; the rendered page is unchanged.';
  result = await produceBundle(identicalDir, declaredIdentical, false);
  if (result.status !== 'READY' || result.expect_identical !== true) {
    throw new Error(`a declared identical proof was rejected: ${result.status} ${result.message}`);
  }

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
  stage=""; session_dir=""; criteria=""
  args=("$@")
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      --stage) stage="${args[$((i+1))]}" ;;
      --session-dir) session_dir="${args[$((i+1))]}" ;;
      --criteria) criteria="${args[$((i+1))]}" ;;
    esac
  done
  if [[ "$stage" == "after" && -n "$session_dir" ]]; then
    mkdir -p "$session_dir"
    printf 'bundle\n' > "$session_dir/walkthrough.mp4"
    printf '%s\n' "{\"version\":3,\"status\":\"READY\",\"message\":\"fixture bundle ready\",\"manifest\":\"$session_dir/visual-evidence.md\",\"video\":\"$session_dir/walkthrough.mp4\",\"poster\":\"\",\"criteria\":[{\"index\":1,\"text\":\"Saving confirms the change\",\"before\":\"unsatisfied\",\"after\":\"satisfied\"}],\"criteria_file\":\"$criteria\"}" > "$session_dir/bundle.json"
    printf 'bundle: %s\n' "$session_dir/bundle.json"
    exit 0
  fi
  printf '%s\n' 'fixture capture failed' >&2
  [[ -n "$criteria" ]] && printf 'criteria passed: %s\n' "$criteria" >&2
  exit 17
fi
exec "$REAL_NODE" "$@"
SH
chmod +x "$FAKE_BIN/node"

# A valid approved-criteria file for the session reaches the producer so the
# criteria table can print the text; the wrapper passes it as --criteria.
CRITERIA_FILE="$(dx_review_criteria_file "ui-capture-failure")"
mkdir -p "$(dirname "$CRITERIA_FILE")"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Confirm saves"],"acceptance_criteria":["Saving confirms the change"],"verification_requirements":["The settings tests pass"]}' > "$CRITERIA_FILE"
dx_review_criteria_valid "$CRITERIA_FILE" || assert_at $LINENO

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
assert_contains "criteria passed: $CRITERIA_FILE" "$(dx_ui_capture_session_dir "$FAILURE_SID")/before-capture-error.log"
assert_contains 'UI proof: NEEDS_REVIEW' "$TMP_DIR/capture-failure.out"

# The producer's criteria table is recorded in evidence.json for the lifecycle.
BUNDLE_SID="ui-capture-bundle"
PATH="$FAKE_BIN:$PATH" REAL_NODE="$REAL_NODE" bash "$ROOT/bin/ui-capture.sh" capture \
  --session "$BUNDLE_SID" --stage after --script "$VALID_SCRIPT" \
  --url "http://127.0.0.1:49999" > "$TMP_DIR/capture-bundle.out" 2>&1
assert_eq "READY" "$(dx_ui_capture_status "$BUNDLE_SID")" "fixture bundle status"
assert_contains '"criteria"' "$(dx_ui_capture_evidence_file "$BUNDLE_SID")"
assert_contains 'Saving confirms the change' "$(dx_ui_capture_evidence_file "$BUNDLE_SID")"

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
printf 'contact\n' > "$SESSION_DIR/contact.png"
dx_ui_capture_register_bundle "$SID"
assert_file "$(dx_run_artifact_file "$RUN_ID" "ui-proof/walkthrough.mp4")"
assert_file "$(dx_run_artifact_file "$RUN_ID" "ui-proof/contact.png")"
assert_contains '"type": "ui_contact_sheet"' "$(dx_run_artifact_manifest_file "$RUN_ID")"
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
dx_ui_capture_write_status "$SID" "READY" "Walkthrough ready" "$MANIFEST" "$VIDEO" active 0 \
  '[{"index":2,"text":"Email toggles persist","before":null,"after":"satisfied"}]'
assert_contains '"criteria"' "$EVIDENCE"
assert_contains 'Email toggles persist' "$EVIDENCE"
assert_rejected "criteria that is not a JSON list" dx_ui_capture_write_status "$SID" "READY" "bad criteria" "$MANIFEST" "$VIDEO" active 0 '{"index":1}'

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

# Browser MCPs use the same installed Chromium as capture, including headless hosts.
DX_TOOL_DIR="$TMP_DIR/browser-tools" node --input-type=commonjs - "$DEX_DIR/scripts/browser-mcp.cjs" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const directory = path.join(process.env.DX_TOOL_DIR, 'ui-capture/node_modules/playwright');
fs.mkdirSync(directory, { recursive: true });
const executable = path.join(directory, 'chromium');
fs.writeFileSync(executable, '');
fs.writeFileSync(path.join(directory, 'index.js'), `exports.chromium = { executablePath: () => ${JSON.stringify(executable)} };`);
const { command } = require(process.argv[2]);
for (const name of ['playwright', 'chrome-devtools']) {
  const args = command(name, [], { DX_TOOL_DIR: process.env.DX_TOOL_DIR });
  assert.ok(args.includes(executable));
  assert.ok(args.includes('--isolated'));
  assert.equal(args.includes('--headless'), process.platform === 'linux');
  const profileOption = name === 'playwright' ? '--user-data-dir' : '--userDataDir';
  assert.ok(!command(name, [profileOption, '/fake/custom-profile']).includes('--isolated'));
}
fs.unlinkSync(executable);
assert.throws(() => command('playwright'), /Chromium is missing/);
JS
python3 - "$DEX_DIR/scripts/browser-mcp-legacy.py" "$TMP_DIR" <<'PYTEST'
import importlib.util
import json
import os
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("browser", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(sys.argv[2]) / 'browser-config'
root.mkdir()
os.environ['CLAUDE_CONFIG_DIR'] = str(root)
file = root / '.claude.json'
entry = {'command': 'npx', 'args': ['-y', '@playwright/mcp@latest']}
file.write_text(json.dumps({'mcpServers': {'playwright': entry}}))
if not module.legacy('claude', 'playwright', '@playwright/mcp@latest'):
    raise AssertionError('bare defaults must migrate')
entry['args'].append('--extension')
file.write_text(json.dumps({'mcpServers': {'playwright': entry}}))
if module.legacy('claude', 'playwright', '@playwright/mcp@latest'):
    raise AssertionError('custom browser configuration must survive')
PYTEST

printf 'ui capture tests passed\n'
