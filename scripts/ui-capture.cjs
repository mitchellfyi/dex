#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { spawnSync } = require('child_process');

const ALLOWED_ACTIONS = new Set([
  'goto', 'click', 'fill', 'press', 'hover', 'scroll', 'wait', 'waitFor', 'assert', 'screenshot',
]);
const ALLOWED_ACTION_KEYS = new Set([
  'action', 'path', 'locator', 'text', 'env', 'key', 'ms', 'state', 'timeout_ms', 'y', 'name',
]);
const ALLOWED_LOCATORS = new Set(['role', 'label', 'text', 'testid']);
const ALLOWED_WAIT_STATES = new Set(['attached', 'detached', 'visible', 'hidden']);
const VALID_STAGES = new Set(['before', 'after']);
const PR_IMAGE_EXTENSIONS = new Set(['.gif', '.jpeg', '.jpg', '.png', '.svg']);
const PR_VIDEO_EXTENSIONS = new Set(['.mov', '.mp4', '.webm']);

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const options = {
    mode: 'capture',
    waitMs: 700,
    desktop: false,
    mobile: false,
    video: false,
    trace: false,
    narration: true,
  };
  let index = 0;
  if (argv[0] && !argv[0].startsWith('-')) {
    options.mode = argv[0];
    index = 1;
  }

  for (; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case '--url': options.url = argv[++index]; break;
      case '--before-url': options.beforeUrl = argv[++index]; break;
      case '--after-url': options.afterUrl = argv[++index]; break;
      case '--out': options.out = argv[++index]; break;
      case '--session-dir': options.sessionDir = argv[++index]; break;
      case '--name': options.name = argv[++index]; break;
      case '--stage': options.stage = argv[++index]; break;
      case '--script': options.script = argv[++index]; break;
      case '--flow': options.flow = argv[++index]; break;
      case '--wait-ms': options.waitMs = Number(argv[++index]); break;
      case '--desktop': options.desktop = true; break;
      case '--mobile': options.mobile = true; options.desktop = true; break;
      case '--video': options.video = true; break;
      case '--trace': options.trace = true; break;
      case '--no-narration': options.narration = false; break;
      default: fail(`Unknown argument: ${arg}`);
    }
  }

  if (!['validate', 'capture', 'revise'].includes(options.mode)) {
    fail(`Unknown mode: ${options.mode}`);
  }
  if (!Number.isFinite(options.waitMs) || options.waitMs < 0 || options.waitMs > 30000) {
    fail('--wait-ms must be between 0 and 30000');
  }
  return options;
}

function requiredString(value, label, maximum = 2000) {
  if (typeof value !== 'string' || !value.trim()) fail(`${label} must be a non-empty string`);
  if (value.length > maximum) fail(`${label} exceeds ${maximum} characters`);
  return value.trim();
}

function webUrl(value, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (error) {
    fail(`${label} must be an absolute HTTP or HTTPS URL (${error.message})`);
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    fail(`${label} must use HTTP or HTTPS`);
  }
  if (parsed.username || parsed.password) {
    fail(`${label} must not contain embedded credentials`);
  }
  return parsed.toString();
}

function validateLocator(locator, label) {
  if (!locator || typeof locator !== 'object' || Array.isArray(locator)) {
    fail(`${label}.locator must be an object`);
  }
  const locatorKind = typeof locator.by === 'string' ? locator.by.toLowerCase() : locator.by;
  if (!ALLOWED_LOCATORS.has(locatorKind)) {
    fail(`${label}.locator.by must be role, label, text, or testid`);
  }
  locator.by = locatorKind;
  requiredString(locator.name, `${label}.locator.name`, 500);
  if (locator.by === 'role') requiredString(locator.role, `${label}.locator.role`, 80);
  for (const key of Object.keys(locator)) {
    if (!['by', 'role', 'name', 'exact'].includes(key)) {
      fail(`${label}.locator contains unsupported key: ${key}`);
    }
  }
}

function validateAction(action, label) {
  if (!action || typeof action !== 'object' || Array.isArray(action)) fail(`${label} must be an object`);
  if (!ALLOWED_ACTIONS.has(action.action)) fail(`${label}.action is unsupported: ${action.action}`);
  for (const key of Object.keys(action)) {
    if (!ALLOWED_ACTION_KEYS.has(key)) fail(`${label} contains unsupported key: ${key}`);
  }
  if (['click', 'fill', 'hover', 'scroll', 'waitFor', 'assert'].includes(action.action) && action.locator) {
    validateLocator(action.locator, label);
  } else if (['click', 'fill', 'hover', 'waitFor', 'assert'].includes(action.action)) {
    fail(`${label}.locator is required for ${action.action}`);
  }
  if (action.action === 'goto') requiredString(action.path, `${label}.path`, 2048);
  if (action.action === 'fill') {
    const hasText = typeof action.text === 'string';
    const hasEnv = typeof action.env === 'string' && action.env.length > 0;
    if (hasText === hasEnv) fail(`${label} fill requires exactly one of text or env`);
    if (hasText && action.text.length > 2000) fail(`${label}.text exceeds 2000 characters`);
  }
  if (action.action === 'press') requiredString(action.key, `${label}.key`, 80);
  if (action.action === 'wait') {
    if (!Number.isInteger(action.ms) || action.ms < 0 || action.ms > 5000) {
      fail(`${label}.ms must be an integer between 0 and 5000`);
    }
  }
  if (action.action === 'waitFor') {
    if (action.state !== undefined && !ALLOWED_WAIT_STATES.has(action.state)) {
      fail(`${label}.state must be attached, detached, visible, or hidden`);
    }
    if (action.timeout_ms !== undefined
      && (!Number.isInteger(action.timeout_ms) || action.timeout_ms < 1 || action.timeout_ms > 60000)) {
      fail(`${label}.timeout_ms must be an integer between 1 and 60000`);
    }
  }
  if (action.action === 'scroll' && !action.locator) {
    if (!Number.isInteger(action.y) || Math.abs(action.y) > 5000) {
      fail(`${label}.y must be an integer between -5000 and 5000`);
    }
  }
  if (action.action === 'screenshot') requiredString(action.name, `${label}.name`, 120);
}

function actionInvalidatesReadiness(action) {
  return ['goto', 'click', 'fill', 'press', 'hover', 'scroll'].includes(action.action);
}

function validateCaptureReadiness(storyboard) {
  for (const stage of VALID_STAGES) {
    const chapters = storyboard.chapters.filter((chapter) => chapter.stage === stage);
    if (chapters.length === 0) continue;
    let readinessSatisfied = false;
    for (const chapter of chapters) {
      for (const action of chapter.actions) {
        if (actionInvalidatesReadiness(action)) readinessSatisfied = false;
        if (action.action === 'waitFor' || action.action === 'assert') readinessSatisfied = true;
        if (action.action === 'screenshot' && !readinessSatisfied) {
          fail(`${stage} screenshot "${action.name}" must follow waitFor or assert after the last state-changing action`);
        }
      }
    }
    if (!readinessSatisfied) {
      fail(`${stage} final screenshot must follow waitFor or assert after the last state-changing action; fixed waits are not a readiness gate`);
    }
  }
}

function loadStoryboard(filePath) {
  if (!filePath) fail('--script is required');
  let value;
  try {
    value = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    fail(`Could not read storyboard ${filePath}: ${error.message}`);
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('storyboard must be a JSON object');
  if (value.version !== 1) fail('storyboard.version must be 1');
  for (const key of ['name', 'title', 'summary', 'product_context', 'technical_summary', 'how_to_test']) {
    requiredString(value[key], `storyboard.${key}`);
  }
  if (!Number.isInteger(value.target_seconds) || value.target_seconds < 15 || value.target_seconds > 90) {
    fail('storyboard.target_seconds must be an integer between 15 and 90');
  }
  if (!Number.isInteger(value.max_seconds) || value.max_seconds < value.target_seconds || value.max_seconds > 90) {
    fail('storyboard.max_seconds must be between target_seconds and 90');
  }
  value.comparison = value.comparison || 'before_after';
  if (!['before_after', 'after_only'].includes(value.comparison)) {
    fail('storyboard.comparison must be before_after or after_only');
  }
  if (value.comparison === 'after_only') {
    requiredString(value.baseline_reason, 'storyboard.baseline_reason');
  }
  if (value.suppress !== undefined) {
    if (!Array.isArray(value.suppress) || value.suppress.length > 20) {
      fail('storyboard.suppress must be an array with at most 20 CSS selectors');
    }
    value.suppress = value.suppress.map((selector, index) => (
      requiredString(selector, `storyboard.suppress[${index}]`, 500)
    ));
  } else {
    value.suppress = [];
  }
  if (!Array.isArray(value.chapters) || value.chapters.length < 1 || value.chapters.length > 12) {
    fail('storyboard.chapters must contain between 1 and 12 chapters');
  }
  const stages = new Set();
  value.chapters.forEach((chapter, chapterIndex) => {
    const label = `storyboard.chapters[${chapterIndex}]`;
    if (!chapter || typeof chapter !== 'object' || Array.isArray(chapter)) fail(`${label} must be an object`);
    if (!VALID_STAGES.has(chapter.stage)) fail(`${label}.stage must be before or after`);
    stages.add(chapter.stage);
    requiredString(chapter.title, `${label}.title`, 120);
    requiredString(chapter.narration, `${label}.narration`, 1000);
    if (!Array.isArray(chapter.actions) || chapter.actions.length === 0 || chapter.actions.length > 40) {
      fail(`${label}.actions must contain between 1 and 40 actions`);
    }
    chapter.actions.forEach((action, actionIndex) => validateAction(action, `${label}.actions[${actionIndex}]`));
  });
  const requiredStages = value.comparison === 'before_after' ? VALID_STAGES : new Set(['after']);
  for (const stage of requiredStages) {
    if (!stages.has(stage)) fail(`storyboard must include at least one ${stage} chapter`);
  }
  if (value.comparison === 'after_only' && stages.has('before')) {
    fail('after_only storyboards must not include before chapters');
  }
  validateCaptureReadiness(value);
  const transcriptSeconds = estimatedSeconds(value);
  if (transcriptSeconds > value.max_seconds) {
    fail(`storyboard narration is approximately ${transcriptSeconds}s and exceeds max_seconds ${value.max_seconds}`);
  }
  return value;
}

function narrationText(storyboard) {
  return orderedChapters(storyboard).map(({ chapter }) => chapter.narration.trim()).join(' ');
}

function estimatedSeconds(storyboard) {
  const words = narrationText(storyboard).split(/\s+/u).filter(Boolean).length;
  return Math.max(1, Math.ceil((words / 150) * 60));
}

function estimatedChapterSeconds(chapter) {
  const words = chapter.narration.trim().split(/\s+/u).filter(Boolean).length;
  return Math.max(1, (words / 150) * 60);
}

function orderedChapters(storyboard) {
  const stages = storyboard.comparison === 'after_only' ? ['after'] : ['before', 'after'];
  return stages.flatMap((stage) => storyboard.chapters
    .map((chapter, chapterIndex) => ({ chapter, chapterIndex }))
    .filter(({ chapter }) => chapter.stage === stage));
}

function stableHash(value) {
  return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

function prMediaKind(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  if (PR_IMAGE_EXTENSIONS.has(extension)) return 'image';
  if (PR_VIDEO_EXTENSIONS.has(extension)) return 'video';
  return null;
}

function pathWithin(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function regularMediaFile(root, candidate) {
  if (!pathWithin(root, candidate) || !prMediaKind(candidate)) return false;
  try {
    const details = fs.lstatSync(candidate);
    return details.isFile() && !details.isSymbolicLink() && details.size > 0
      && pathWithin(fs.realpathSync(root), fs.realpathSync(candidate));
  } catch (_) {
    return false;
  }
}

function mediaFilesUnder(root) {
  const files = [];
  function visit(directory) {
    let entries;
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch (_) {
      return;
    }
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue;
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(candidate);
      } else if (entry.isFile() && regularMediaFile(root, candidate)) {
        files.push(candidate);
      }
    }
  }
  visit(root);
  return files;
}

function prAttachment(sessionDir, filePath, stage, title) {
  const kind = prMediaKind(filePath);
  const baseName = path.basename(filePath, path.extname(filePath)).replace(/[-_]+/gu, ' ').trim();
  const imageAlt = stage === 'poster'
    ? `${title} walkthrough poster`
    : `${title} ${stage} ${baseName}`;
  return {
    path: path.resolve(filePath),
    kind,
    stage,
    alt: kind === 'image' ? imageAlt.replace(/\s+/gu, ' ').trim() : '',
    relative_path: path.relative(path.resolve(sessionDir), path.resolve(filePath)),
  };
}

function prAttachmentInventory(sessionDir, storyboard, before, after, finalVideo, poster) {
  const attachments = [];
  const seen = new Set();
  function add(filePath, stage, allowedRoot = sessionDir) {
    const resolved = path.resolve(filePath);
    if (seen.has(resolved) || !regularMediaFile(sessionDir, resolved)
      || !regularMediaFile(allowedRoot, resolved)) return;
    seen.add(resolved);
    attachments.push(prAttachment(sessionDir, resolved, stage, storyboard.title));
  }
  add(finalVideo, 'walkthrough');
  add(poster, 'poster');
  for (const [stage, record] of [['before', before], ['after', after]]) {
    if (!record || !pathWithin(sessionDir, record.directory)) continue;
    const recordRoot = path.resolve(record.directory);
    for (const result of Array.isArray(record.results) ? record.results : []) {
      if (result && typeof result.screenshot === 'string') add(result.screenshot, stage, recordRoot);
      for (const video of result && Array.isArray(result.videos) ? result.videos : []) add(video, stage, recordRoot);
    }
    for (const mediaFile of mediaFilesUnder(recordRoot)) add(mediaFile, stage, recordRoot);
  }
  const fingerprintInput = attachments.map((attachment) => ({
    relative_path: attachment.relative_path,
    kind: attachment.kind,
    stage: attachment.stage,
    sha256: crypto.createHash('sha256').update(fs.readFileSync(attachment.path)).digest('hex'),
  }));
  return {
    attachments,
    fingerprint: stableHash(fingerprintInput),
  };
}

function stageHash(storyboard, stage) {
  return stableHash({
    captureContractVersion: 2,
    suppress: storyboard.suppress || [],
    chapters: storyboard.chapters.filter((chapter) => chapter.stage === stage),
  });
}

function slugify(value) {
  return String(value || 'capture').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80) || 'capture';
}

function writeLines(filePath, lines) {
  fs.writeFileSync(filePath, `${lines.join('\n')}${lines.length ? '\n' : ''}`);
}

function playwrightModule() {
  const toolsDir = process.env.DX_UI_CAPTURE_TOOLS_DIR;
  if (!toolsDir) fail('DX_UI_CAPTURE_TOOLS_DIR is not set');
  return require(path.join(toolsDir, 'node_modules', 'playwright'));
}

async function safeGoto(page, url) {
  try {
    await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 });
  } catch (error) {
    const message = String(error && error.message ? error.message : error);
    if (/networkidle|Navigation timeout/i.test(message)) {
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
        return;
      } catch (fallbackError) {
        const fallbackMessage = String(fallbackError && fallbackError.message ? fallbackError.message : fallbackError);
        fail(`Navigation to ${url} failed after the network-idle fallback: ${fallbackMessage}`);
      }
    }
    const addressHint = /ERR_CONNECTION_REFUSED|ECONNREFUSED/i.test(message)
      ? ' Verify that the app is listening on this address (127.0.0.1 for IPv4, [::1] for IPv6, or localhost).'
      : '';
    fail(`Navigation to ${url} failed: ${message}${addressHint}`);
  }
}

async function installSuppressions(context, selectors) {
  if (!selectors || selectors.length === 0) return;
  await context.addInitScript((suppressedSelectors) => {
    const style = document.createElement('style');
    style.id = '__dex_ui_suppressions';
    style.textContent = suppressedSelectors.map((selector) => `${selector} { display: none !important; }`).join('\n');
    document.documentElement.appendChild(style);
  }, selectors);
}

function locatorFor(page, spec) {
  const options = { exact: spec.exact === true };
  switch (spec.by) {
    case 'role': return page.getByRole(spec.role, { name: spec.name, ...options });
    case 'label': return page.getByLabel(spec.name, options);
    case 'text': return page.getByText(spec.name, options);
    case 'testid': return page.getByTestId(spec.name);
    default: fail(`Unsupported locator: ${spec.by}`);
  }
}

async function ensureOverlay(page, stage) {
  await page.evaluate((stageName) => {
    let root = document.getElementById('__dex_ui_proof');
    if (!root) {
      root = document.createElement('div');
      root.id = '__dex_ui_proof';
      root.innerHTML = '<div class="dex-stage"></div><div class="dex-caption"><strong></strong><span></span></div><div class="dex-cursor"></div>';
      document.documentElement.appendChild(root);
      const style = document.createElement('style');
      style.id = '__dex_ui_proof_style';
      style.textContent = `
        #__dex_ui_proof { position: fixed; inset: 0; z-index: 2147483647; pointer-events: none; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        #__dex_ui_proof .dex-stage { position: absolute; top: 20px; left: 20px; padding: 7px 12px; border-radius: 999px; background: rgba(15,23,42,.88); color: white; font-size: 15px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; box-shadow: 0 4px 18px rgba(0,0,0,.24); }
        #__dex_ui_proof .dex-caption { position: absolute; left: 8%; right: 8%; bottom: 24px; padding: 12px 16px; border-radius: 12px; background: rgba(15,23,42,.9); color: white; text-align: center; opacity: 0; transition: opacity .2s ease; box-shadow: 0 6px 24px rgba(0,0,0,.3); }
        #__dex_ui_proof .dex-caption strong { display: block; margin-bottom: 3px; color: #7dd3fc; font-size: 16px; }
        #__dex_ui_proof .dex-caption span { font-size: 15px; line-height: 1.35; }
        #__dex_ui_proof .dex-cursor { position: absolute; width: 20px; height: 20px; margin: -10px 0 0 -10px; border: 3px solid white; border-radius: 50%; background: #0ea5e9; box-shadow: 0 0 0 3px rgba(14,165,233,.32), 0 3px 10px rgba(0,0,0,.35); transform: translate(-30px,-30px); transition: transform .35s ease; }
      `;
      document.documentElement.appendChild(style);
    }
    root.querySelector('.dex-stage').textContent = stageName;
  }, stage);
}

async function showChapter(page, chapter) {
  await ensureOverlay(page, chapter.stage);
  await page.evaluate(({ title, narration }) => {
    const caption = document.querySelector('#__dex_ui_proof .dex-caption');
    caption.querySelector('strong').textContent = title;
    caption.querySelector('span').textContent = narration;
    caption.style.opacity = '1';
  }, chapter);
  await page.waitForTimeout(900);
}

async function pointAt(page, locator) {
  await locator.scrollIntoViewIfNeeded();
  const box = await locator.boundingBox();
  if (!box) fail('Target element is not visible');
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.evaluate(({ xPos, yPos }) => {
    const cursor = document.querySelector('#__dex_ui_proof .dex-cursor');
    cursor.style.transform = `translate(${xPos}px,${yPos}px)`;
  }, { xPos: x, yPos: y });
  await page.mouse.move(x, y, { steps: 12 });
  const previousStyle = await locator.evaluate((element) => ({
    outline: element.style.outline,
    outlineOffset: element.style.outlineOffset,
    boxShadow: element.style.boxShadow,
  }));
  await locator.evaluate((element) => {
    element.style.outline = '3px solid #0ea5e9';
    element.style.outlineOffset = '4px';
    element.style.boxShadow = '0 0 0 8px rgba(14,165,233,.22)';
  });
  await page.waitForTimeout(450);
  return {
    async dispose() {
      try {
        await locator.evaluate((element, original) => {
          element.style.outline = original.outline;
          element.style.outlineOffset = original.outlineOffset;
          element.style.boxShadow = original.boxShadow;
        }, previousStyle);
      } catch (_) {
        // A click may intentionally navigate away before the highlight clears.
      }
    },
  };
}

async function runAction({ page, action, baseUrl, screenshot, stage }) {
  if (action.action === 'goto') {
    await safeGoto(page, webUrl(new URL(action.path, baseUrl).toString(), 'goto URL'));
    await ensureOverlay(page, stage);
    return;
  }
  if (action.action === 'wait') {
    await page.waitForTimeout(action.ms);
    return;
  }
  if (action.action === 'waitFor') {
    const locator = locatorFor(page, action.locator);
    await locator.waitFor({
      state: action.state || 'visible',
      timeout: action.timeout_ms || 30000,
    });
    return;
  }
  if (action.action === 'press') {
    await page.keyboard.press(action.key);
    return;
  }
  if (action.action === 'screenshot') {
    await screenshot(action.name);
    return;
  }
  if (action.action === 'scroll' && !action.locator) {
    await page.mouse.wheel(0, action.y);
    await page.waitForTimeout(450);
    return;
  }

  const locator = locatorFor(page, action.locator);
  if (action.action === 'assert') {
    await locator.waitFor({ state: 'visible', timeout: 10000 });
    const highlight = await pointAt(page, locator);
    await highlight.dispose();
    return;
  }
  if (action.action === 'scroll') {
    await locator.scrollIntoViewIfNeeded();
    const highlight = await pointAt(page, locator);
    await highlight.dispose();
    return;
  }

  const highlight = await pointAt(page, locator);
  try {
    if (action.action === 'click') await locator.click();
    if (action.action === 'hover') await locator.hover();
    if (action.action === 'fill') {
      const value = action.env ? process.env[action.env] : action.text;
      if (action.env && typeof value !== 'string') fail(`Missing environment value: ${action.env}`);
      await locator.fill(value);
    }
  } finally {
    if (highlight && typeof highlight.dispose === 'function') await highlight.dispose();
  }
  await page.waitForTimeout(500);
}

async function runStoryboardStage({ page, options, storyboard, viewportName, outDir, startedAt }) {
  const chapters = storyboard.chapters
    .map((chapter, chapterIndex) => ({ chapter, chapterIndex }))
    .filter(({ chapter }) => chapter.stage === options.stage);
  const timelineStartedAt = startedAt || Date.now();
  const timeline = [];
  const readiness = [];
  for (const { chapter, chapterIndex } of chapters) {
    let chapterShown = false;
    let chapterStartedAt = null;
    for (const action of chapter.actions) {
      if (action.action !== 'goto' && !chapterShown) {
        chapterStartedAt = Date.now();
        await showChapter(page, chapter);
        chapterShown = true;
      }
      await runAction({
        page,
        action,
        baseUrl: options.url,
        stage: options.stage,
        screenshot: async (name) => {
          const screenshotPath = path.join(outDir, `${viewportName}-${slugify(name)}.png`);
          await page.screenshot({ path: screenshotPath, fullPage: true });
          return screenshotPath;
        },
      });
      if (action.action === 'goto') {
        chapterStartedAt = Date.now();
        await showChapter(page, chapter);
        chapterShown = true;
      }
      if (action.action === 'waitFor' || action.action === 'assert') {
        readiness.push({
          chapterIndex,
          action: action.action,
          locator: action.locator,
          state: action.action === 'waitFor' ? (action.state || 'visible') : 'visible',
        });
      }
    }
    timeline.push({
      chapterIndex,
      startSeconds: Math.max(0, ((chapterStartedAt || timelineStartedAt) - timelineStartedAt) / 1000),
      endSeconds: Math.max(0.001, (Date.now() - timelineStartedAt) / 1000),
    });
  }
  return {
    actionCount: chapters.reduce((total, { chapter }) => total + chapter.actions.length, 0),
    readiness,
    readinessSatisfied: readiness.length > 0,
    timeline,
  };
}

async function runViewport({ browser, playwright, options, storyboard, viewportName, viewport }) {
  const outDir = options.out;
  const videoDir = path.join(outDir, 'video', viewportName);
  const contextOptions = viewportName === 'mobile'
    ? { ...playwright.devices['iPhone 15'], viewport, deviceScaleFactor: 1, ignoreHTTPSErrors: true }
    : { viewport, deviceScaleFactor: 1, ignoreHTTPSErrors: true };
  if (options.video || storyboard) {
    fs.mkdirSync(videoDir, { recursive: true });
    contextOptions.recordVideo = { dir: videoDir, size: viewport };
  }

  const context = await browser.newContext(contextOptions);
  const tracePath = path.join(outDir, `${viewportName}-trace.zip`);
  const shouldTrace = options.trace || Boolean(storyboard);
  let traceStarted = false;
  let captureError = null;
  let storyboardExecution = null;
  let screenshotPath = null;
  const consoleErrors = [];
  const pageErrors = [];
  const networkErrors = [];
  const responses = [];
  try {
    await installSuppressions(context, storyboard ? storyboard.suppress : []);
    if (shouldTrace) {
      await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
      traceStarted = true;
    }

    const startedAt = Date.now();
    const page = await context.newPage();
    page.on('console', (message) => { if (['error', 'warning'].includes(message.type())) consoleErrors.push(`[${message.type()}] ${message.text()}`); });
    page.on('pageerror', (error) => pageErrors.push(error.stack || error.message || String(error)));
    page.on('requestfailed', (request) => networkErrors.push(`${request.method()} ${request.url()} :: ${(request.failure() || {}).errorText || 'failed'}`));
    page.on('response', (response) => { if (response.status() >= 400) responses.push(`${response.status()} ${response.url()}`); });

    await safeGoto(page, options.url);
    await ensureOverlay(page, options.stage || 'capture');
    if (options.waitMs > 0) await page.waitForTimeout(options.waitMs);

    if (storyboard) {
      storyboardExecution = await runStoryboardStage({
        page, options, storyboard, viewportName, outDir, startedAt,
      });
    } else if (options.flow) {
      const flowPath = path.resolve(options.flow);
      const flow = require(flowPath);
      const runner = typeof flow === 'function' ? flow : flow.run;
      if (typeof runner !== 'function') fail(`Flow file must export a function or { run }; got ${flowPath}`);
      await runner({
        page, context, viewportName, artifactsDir: outDir,
        screenshot: async (name) => {
          const flowScreenshotPath = path.join(outDir, `${viewportName}-${slugify(name)}.png`);
          await page.screenshot({ path: flowScreenshotPath, fullPage: true });
          return flowScreenshotPath;
        },
      });
    }

    if (options.waitMs > 0) await page.waitForTimeout(options.waitMs);
    screenshotPath = path.join(outDir, `${viewportName}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: !storyboard });
  } catch (error) {
    captureError = error;
  }

  if (traceStarted) {
    try {
      // Export the multi-MB zip only when someone will read it — an explicit
      // --trace, or a failure whose evidence it carries. A clean run used to
      // serialize it and delete it two statements later.
      if (options.trace || captureError) {
        await context.tracing.stop({ path: tracePath });
      } else {
        await context.tracing.stop();
      }
    } catch (error) {
      if (!captureError) captureError = error;
    }
  }
  try {
    await context.close();
  } catch (error) {
    if (!captureError) captureError = error;
  }
  if (captureError) {
    const traceNote = traceStarted && fs.existsSync(tracePath) ? ` Failure trace: ${tracePath}` : '';
    fail(`${String(captureError && captureError.message ? captureError.message : captureError)}${traceNote}`);
  }

  const videoFiles = fs.existsSync(videoDir)
    ? fs.readdirSync(videoDir).filter((file) => file.endsWith('.webm')).map((file) => path.join(videoDir, file))
    : [];
  return {
    viewport: viewportName,
    viewportSize: viewport,
    screenshot: screenshotPath,
    trace: options.trace ? tracePath : null,
    videos: videoFiles,
    storyboardExecution,
    suppressedSelectors: storyboard ? storyboard.suppress : [],
    consoleErrors,
    pageErrors,
    networkErrors,
    httpErrors: responses,
  };
}

async function captureStage(options, storyboard) {
  if (!options.url) fail('--url is required for capture');
  if (!options.out) fail('--out is required for capture');
  if (storyboard && !VALID_STAGES.has(options.stage)) fail('--stage before or --stage after is required with --script');
  options.url = webUrl(options.url, '--url');
  if (!options.desktop && !options.mobile) options.desktop = true;
  fs.mkdirSync(options.out, { recursive: true });
  const playwright = playwrightModule();
  const browser = await playwright.chromium.launch({ headless: true });
  const results = [];
  try {
    if (options.desktop) results.push(await runViewport({ browser, playwright, options, storyboard, viewportName: 'desktop', viewport: { width: 1440, height: 900 } }));
    if (options.mobile) results.push(await runViewport({ browser, playwright, options, storyboard, viewportName: 'mobile', viewport: { width: 390, height: 844 } }));
  } finally {
    await browser.close();
  }

  const metadata = {
    version: 3,
    name: options.name || (storyboard && storyboard.name) || 'capture',
    stage: options.stage || null,
    url: options.url,
    capturedAt: new Date().toISOString(),
    flow: options.flow ? path.resolve(options.flow) : null,
    storyboard: options.script ? path.resolve(options.script) : null,
    storyboardHash: storyboard ? stableHash(storyboard) : null,
    stageHash: storyboard ? stageHash(storyboard, options.stage) : null,
    results,
  };
  fs.writeFileSync(path.join(options.out, 'metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
  writeLines(path.join(options.out, 'console-errors.log'), results.flatMap((result) => result.consoleErrors.map((line) => `[${result.viewport}] ${line}`)));
  writeLines(path.join(options.out, 'page-errors.log'), results.flatMap((result) => result.pageErrors.map((line) => `[${result.viewport}] ${line}`)));
  writeLines(path.join(options.out, 'network-errors.log'), results.flatMap((result) => result.networkErrors.map((line) => `[${result.viewport}] ${line}`)));
  writeLines(path.join(options.out, 'http-errors.log'), results.flatMap((result) => result.httpErrors.map((line) => `[${result.viewport}] ${line}`)));
  return metadata;
}

function captureRecords(sessionDir) {
  if (!fs.existsSync(sessionDir)) return [];
  const records = [];
  for (const entry of fs.readdirSync(sessionDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const metadataPath = path.join(sessionDir, entry.name, 'metadata.json');
    if (!fs.existsSync(metadataPath)) continue;
    try {
      const value = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
      if (VALID_STAGES.has(value.stage)) records.push({ ...value, directory: path.dirname(metadataPath) });
    } catch (_) {
      // A corrupt capture is ignored and reported as missing by the producer.
    }
  }
  return records.sort((left, right) => String(right.capturedAt).localeCompare(String(left.capturedAt)));
}

function matchingStageRecord(records, stage, storyboard) {
  const wantedHash = stageHash(storyboard, stage);
  return records.find((record) => record.stage === stage && record.stageHash === wantedHash);
}

function latestStageRecord(records, stage) {
  return records.find((record) => record.stage === stage);
}

function primaryVideo(record) {
  if (!record) return null;
  const result = primaryResult(record);
  return result && result.videos && result.videos.find((video) => fs.existsSync(video));
}

function primaryResult(record) {
  if (!record || !Array.isArray(record.results)) return null;
  return record.results.find((candidate) => candidate.viewport === 'desktop') || record.results[0] || null;
}

function captureExecutionVerified(record, storyboard, stage) {
  const expectedChapters = storyboard.chapters
    .map((chapter, chapterIndex) => ({ chapter, chapterIndex }))
    .filter(({ chapter }) => chapter.stage === stage);
  const expectedActionCount = expectedChapters
    .reduce((total, { chapter }) => total + chapter.actions.length, 0);
  const expectedChapterIndices = expectedChapters.map(({ chapterIndex }) => chapterIndex);
  return Boolean(record && Array.isArray(record.results) && record.results.length > 0
    && record.results.every((result) => {
      const execution = result.storyboardExecution;
      if (!execution || execution.readinessSatisfied !== true
        || execution.actionCount !== expectedActionCount || !Array.isArray(execution.timeline)
        || !Array.isArray(execution.readiness) || execution.readiness.length === 0) {
        return false;
      }
      const actualChapterIndices = execution.timeline.map((timing) => timing.chapterIndex);
      return JSON.stringify(actualChapterIndices) === JSON.stringify(expectedChapterIndices);
    }));
}

function finalReadinessGate(record) {
  const result = primaryResult(record);
  const readiness = result && result.storyboardExecution && result.storyboardExecution.readiness;
  return Array.isArray(readiness) && readiness.length > 0 ? readiness[readiness.length - 1] : null;
}

function captureViewportContract(record) {
  if (!record || !Array.isArray(record.results)) return [];
  return record.results.map((result) => ({
    name: result.viewport,
    width: result.viewportSize && result.viewportSize.width,
    height: result.viewportSize && result.viewportSize.height,
  })).sort((left, right) => left.name.localeCompare(right.name));
}

function writeTranscript(sessionDir, storyboard) {
  const lines = [
    `# ${storyboard.title}`, '', storyboard.summary, '',
    '## Product context', '', storyboard.product_context, '',
    '## Technical summary', '', storyboard.technical_summary, '',
    '## How to test', '', storyboard.how_to_test, '',
    '## Transcript', '',
  ];
  orderedChapters(storyboard).forEach(({ chapter }) => {
    const stage = chapter.stage === 'before' ? 'Before' : 'After';
    const title = chapter.title.trim();
    const heading = title.toLowerCase() === stage.toLowerCase() || title.toLowerCase().startsWith(`${stage.toLowerCase()}:`)
      ? title
      : `${stage}: ${title}`;
    lines.push(`### ${heading}`, '', chapter.narration, '');
  });
  fs.writeFileSync(path.join(sessionDir, 'transcript.md'), `${lines.join('\n')}\n`);
}

function timecode(seconds) {
  const totalMilliseconds = Math.max(0, Math.round(seconds * 1000));
  const hours = String(Math.floor(totalMilliseconds / 3600000)).padStart(2, '0');
  const minutes = String(Math.floor((totalMilliseconds % 3600000) / 60000)).padStart(2, '0');
  const secs = String(Math.floor((totalMilliseconds % 60000) / 1000)).padStart(2, '0');
  const milliseconds = String(totalMilliseconds % 1000).padStart(3, '0');
  return `${hours}:${minutes}:${secs}.${milliseconds}`;
}

function writeVtt(sessionDir, storyboard, cues) {
  const chapters = new Map(orderedChapters(storyboard).map((entry) => [entry.chapterIndex, entry.chapter]));
  if (!Array.isArray(cues) || cues.length !== chapters.size) {
    fail('Caption timing is incomplete; every storyboard chapter needs a measured cue');
  }
  const vtt = ['WEBVTT', ''];
  const seen = new Set();
  let previousEnd = 0;
  cues.slice().sort((left, right) => left.startSeconds - right.startSeconds).forEach((cue) => {
    const chapter = chapters.get(cue.chapterIndex);
    if (!chapter || !Number.isFinite(cue.startSeconds) || !Number.isFinite(cue.endSeconds)
      || cue.endSeconds <= cue.startSeconds || cue.startSeconds < previousEnd || seen.has(cue.chapterIndex)) {
      fail('Caption timing contains an invalid chapter cue');
    }
    seen.add(cue.chapterIndex);
    previousEnd = cue.endSeconds;
    vtt.push(`${timecode(cue.startSeconds)} --> ${timecode(cue.endSeconds)}`, chapter.narration, '');
  });
  fs.writeFileSync(path.join(sessionDir, 'captions.vtt'), `${vtt.join('\n')}\n`);
}

function captureCaptionCues(storyboard, binary, before, after) {
  const records = new Map([['before', before], ['after', after]]);
  const stages = storyboard.comparison === 'after_only' ? ['after'] : ['before', 'after'];
  const cues = [];
  let stageOffset = 0;
  for (const stage of stages) {
    const record = records.get(stage);
    const result = primaryResult(record);
    const video = primaryVideo(record);
    const duration = video ? mediaDuration(binary, video) : null;
    const timeline = result && result.storyboardExecution && result.storyboardExecution.timeline;
    if (duration === null || !Array.isArray(timeline)) return null;
    for (const { chapterIndex } of orderedChapters(storyboard).filter(({ chapter }) => chapter.stage === stage)) {
      const timing = timeline.find((candidate) => candidate.chapterIndex === chapterIndex);
      if (!timing || !Number.isFinite(timing.startSeconds) || !Number.isFinite(timing.endSeconds)
        || timing.startSeconds < 0 || timing.startSeconds >= duration || timing.endSeconds <= timing.startSeconds) {
        return null;
      }
      cues.push({
        chapterIndex,
        startSeconds: stageOffset + timing.startSeconds,
        endSeconds: stageOffset + Math.min(duration, timing.endSeconds),
      });
    }
    stageOffset += duration;
  }
  return cues;
}

function ffmpegBinary() {
  if (process.env.DX_UI_CAPTURE_FFMPEG) return process.env.DX_UI_CAPTURE_FFMPEG;
  const toolsDir = process.env.DX_UI_CAPTURE_TOOLS_DIR;
  if (!toolsDir) return null;
  try {
    return require(require.resolve('ffmpeg-static', { paths: [toolsDir] }));
  } catch (_) {
    return null;
  }
}

function runFfmpeg(binary, args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  if (result.status !== 0) fail(`FFmpeg failed: ${(result.stderr || result.stdout || '').trim().slice(-2000)}`);
}

function mediaDuration(binary, filePath) {
  const result = spawnSync(binary, ['-i', filePath], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
  const match = String(result.stderr || '').match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/);
  if (!match) return null;
  return (Number(match[1]) * 3600) + (Number(match[2]) * 60) + Number(match[3]);
}

function narrationDurationMatches(actualSeconds, estimatedDuration) {
  if (!Number.isFinite(actualSeconds) || actualSeconds <= 0) return false;
  const tolerance = Math.max(2, estimatedDuration * 0.35);
  return Math.abs(actualSeconds - estimatedDuration) <= tolerance;
}

async function generateNarration(sessionDir, storyboard, binary, services = {}) {
  const toolsDir = process.env.DX_UI_CAPTURE_TOOLS_DIR;
  if (!toolsDir && !services.createTts) return { ok: false, reason: 'tool directory is unavailable' };
  const output = path.join(sessionDir, 'narration.wav');
  const clipsDir = path.join(sessionDir, '.narration-chapters');
  fs.rmSync(output, { force: true });
  fs.rmSync(clipsDir, { recursive: true, force: true });
  fs.mkdirSync(clipsDir, { recursive: true });
  try {
    let tts;
    if (services.createTts) {
      tts = await services.createTts();
    } else {
      const packagePath = require.resolve('kokoro-js', { paths: [toolsDir] });
      const { KokoroTTS } = await import(pathToFileURL(packagePath).href);
      tts = await KokoroTTS.from_pretrained('onnx-community/Kokoro-82M-v1.0-ONNX', { dtype: 'q8', device: 'cpu' });
    }
    const durationOf = services.durationOf || ((filePath) => mediaDuration(binary, filePath));
    const concatenate = services.concatenate || ((clipPaths, targetPath) => {
      const concatFile = path.join(clipsDir, 'concat.txt');
      const escape = (file) => file.replace(/'/g, "'\\''");
      fs.writeFileSync(concatFile, `${clipPaths.map((file) => `file '${escape(file)}'`).join('\n')}\n`);
      runFfmpeg(binary, ['-y', '-f', 'concat', '-safe', '0', '-i', concatFile, '-c:a', 'pcm_s16le', targetPath]);
    });
    const clips = [];
    const cues = [];
    let offset = 0;
    for (const { chapter, chapterIndex } of orderedChapters(storyboard)) {
      const clipPath = path.join(clipsDir, `${String(chapterIndex).padStart(2, '0')}.wav`);
      const audio = await tts.generate(chapter.narration.trim(), {
        voice: process.env.DX_UI_CAPTURE_VOICE || 'bf_emma',
        speed: 1.05,
      });
      await audio.save(clipPath);
      const actualDuration = fs.existsSync(clipPath) && fs.statSync(clipPath).size > 0
        ? durationOf(clipPath)
        : null;
      const expectedDuration = estimatedChapterSeconds(chapter);
      if (!narrationDurationMatches(actualDuration, expectedDuration)) {
        return {
          ok: false,
          incomplete: true,
          reason: `chapter ${chapterIndex + 1} narration duration ${actualDuration === null ? 'could not be measured' : `${actualDuration.toFixed(2)}s`} does not match the ${expectedDuration.toFixed(2)}s estimate`,
        };
      }
      clips.push(clipPath);
      cues.push({ chapterIndex, startSeconds: offset, endSeconds: offset + actualDuration });
      offset += actualDuration;
    }
    concatenate(clips, output);
    const outputDuration = fs.existsSync(output) && fs.statSync(output).size > 0 ? durationOf(output) : null;
    const estimatedDuration = orderedChapters(storyboard)
      .reduce((total, { chapter }) => total + estimatedChapterSeconds(chapter), 0);
    const concatTolerance = Math.max(0.25, offset * 0.02);
    if (!Number.isFinite(outputDuration) || Math.abs(outputDuration - offset) > concatTolerance
      || !narrationDurationMatches(outputDuration, estimatedDuration)) {
      fs.rmSync(output, { force: true });
      return {
        ok: false,
        incomplete: true,
        reason: `combined narration duration ${outputDuration === null ? 'could not be measured' : `${outputDuration.toFixed(2)}s`} does not match the ${estimatedDuration.toFixed(2)}s estimate`,
      };
    }
    return {
      ok: true,
      path: output,
      reason: null,
      durationSeconds: outputDuration,
      estimatedDurationSeconds: estimatedDuration,
      cues,
    };
  } catch (error) {
    fs.rmSync(output, { force: true });
    return { ok: false, reason: String(error && error.message ? error.message : error) };
  } finally {
    fs.rmSync(clipsDir, { recursive: true, force: true });
  }
}

async function produceBundleUnsafe(sessionDir, storyboard, narrationEnabled) {
  fs.mkdirSync(sessionDir, { recursive: true });
  writeTranscript(sessionDir, storyboard);
  const records = captureRecords(sessionDir);
  const before = matchingStageRecord(records, 'before', storyboard);
  const after = matchingStageRecord(records, 'after', storyboard);
  const beforeVideo = primaryVideo(before);
  const afterVideo = primaryVideo(after);
  const requiresBefore = storyboard.comparison !== 'after_only';
  const finalVideo = path.join(sessionDir, 'walkthrough.mp4');
  const poster = path.join(sessionDir, 'poster.png');
  const manifest = path.join(sessionDir, 'visual-evidence.md');
  const captions = path.join(sessionDir, 'captions.vtt');
  fs.rmSync(finalVideo, { force: true });
  fs.rmSync(poster, { force: true });
  fs.rmSync(captions, { force: true });
  const notes = [];
  let status = 'READY';
  let narration = { ok: false, reason: 'disabled' };
  let finalDurationSeconds = null;
  let captionCues = null;

  const readinessSatisfied = (!requiresBefore || captureExecutionVerified(before, storyboard, 'before'))
    && captureExecutionVerified(after, storyboard, 'after');
  const beforeReadinessGate = finalReadinessGate(before);
  const afterReadinessGate = finalReadinessGate(after);
  const beforeViewports = captureViewportContract(before);
  const afterViewports = captureViewportContract(after);
  const viewportParity = !requiresBefore
    || (beforeViewports.length > 0 && stableHash(beforeViewports) === stableHash(afterViewports));
  if ((before || after) && !readinessSatisfied) {
    status = 'NEEDS_REVIEW';
    notes.push('Capture readiness could not be verified for every recorded viewport. Re-run both stages with waitFor or assert gates.');
  }
  if ((before || after) && !viewportParity) {
    status = 'NEEDS_REVIEW';
    notes.push('Before and after viewport sets differ. Re-run the stages with the same viewport names and dimensions.');
  }

  if ((requiresBefore && !beforeVideo) || !afterVideo) {
    status = 'NEEDS_REVIEW';
    notes.push(requiresBefore
      ? 'A matching before and after video is required before the final walkthrough can be rendered.'
      : 'An after video is required before the final walkthrough can be rendered.');
  } else {
    const binary = ffmpegBinary();
    if (!binary || !fs.existsSync(binary)) {
      status = 'NEEDS_REVIEW';
      notes.push('FFmpeg is unavailable; raw source WebM clips were retained.');
    } else {
      const concatFile = path.join(sessionDir, '.walkthrough-concat.txt');
      const escape = (file) => file.replace(/'/g, "'\\''");
      const sourceVideos = requiresBefore ? [beforeVideo, afterVideo] : [afterVideo];
      fs.writeFileSync(concatFile, `${sourceVideos.map((file) => `file '${escape(file)}'`).join('\n')}\n`);
      const silentVideo = path.join(sessionDir, '.walkthrough-silent.mp4');
      runFfmpeg(binary, ['-y', '-f', 'concat', '-safe', '0', '-i', concatFile, '-c:v', 'libx264', '-preset', 'medium', '-crf', '25', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', silentVideo]);
      if (narrationEnabled) narration = await generateNarration(sessionDir, storyboard, binary);
      if (narration.ok) {
        captionCues = narration.cues;
        const silentDuration = mediaDuration(binary, silentVideo);
        const narrationDuration = narration.durationSeconds;
        if (silentDuration !== null && narrationDuration !== null) {
          const finalDuration = Math.max(silentDuration, narrationDuration);
          const videoPadding = Math.max(0, finalDuration - silentDuration);
          runFfmpeg(binary, [
            '-y', '-i', silentVideo, '-i', narration.path,
            '-filter_complex', `[0:v]tpad=stop_mode=clone:stop_duration=${videoPadding.toFixed(3)}[v];[1:a]apad[a]`,
            '-map', '[v]', '-map', '[a]', '-t', finalDuration.toFixed(3),
            '-c:v', 'libx264', '-preset', 'medium', '-crf', '25', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', finalVideo,
          ]);
        } else {
          runFfmpeg(binary, ['-y', '-i', silentVideo, '-i', narration.path, '-filter_complex', '[1:a]apad[a]', '-map', '0:v:0', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k', '-shortest', '-movflags', '+faststart', finalVideo]);
        }
      } else {
        fs.copyFileSync(silentVideo, finalVideo);
        captionCues = captureCaptionCues(storyboard, binary, before, after);
        if (narration.incomplete) status = 'NEEDS_REVIEW';
        if (!narrationEnabled) {
          notes.push('Narration was disabled; the captioned video is ready.');
        } else if (narration.incomplete) {
          notes.push(`Local narration was incomplete and the audio was discarded (${narration.reason}).`);
        } else {
          notes.push(`Local narration unavailable; captions use the measured capture timeline (${narration.reason}).`);
        }
      }
      fs.rmSync(concatFile, { force: true });
      fs.rmSync(silentVideo, { force: true });
      const duration = mediaDuration(binary, finalVideo);
      finalDurationSeconds = duration;
      if (duration === null || duration > storyboard.max_seconds) {
        status = 'NEEDS_REVIEW';
        notes.push(duration === null ? 'Final duration could not be verified.' : `Final duration ${duration.toFixed(1)}s exceeds ${storyboard.max_seconds}s.`);
      }
      const maximumBytes = 10 * 1024 * 1024;
      if (fs.statSync(finalVideo).size > maximumBytes) {
        const compressedVideo = path.join(sessionDir, '.walkthrough-compressed.mp4');
        runFfmpeg(binary, ['-y', '-i', finalVideo, '-c:v', 'libx264', '-preset', 'slow', '-crf', '30', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', compressedVideo]);
        fs.renameSync(compressedVideo, finalVideo);
      }
      if (fs.statSync(finalVideo).size > maximumBytes) {
        status = 'NEEDS_REVIEW';
        notes.push(`Final video is ${(fs.statSync(finalVideo).size / (1024 * 1024)).toFixed(1)} MiB; trim the storyboard before PR upload.`);
      }
      if (captionCues) {
        writeVtt(sessionDir, storyboard, captionCues);
      } else {
        status = 'NEEDS_REVIEW';
        notes.push('Caption timing could not be measured from narration or the captured chapter timeline.');
      }
    }
  }

  const afterResult = after && (after.results.find((item) => item.viewport === 'desktop') || after.results[0]);
  if (afterResult && afterResult.screenshot && fs.existsSync(afterResult.screenshot)) fs.copyFileSync(afterResult.screenshot, poster);
  const prInventory = prAttachmentInventory(sessionDir, storyboard, before, after, finalVideo, poster);

  const manifestLines = [
    '# Visual Proof', '', `Status: ${status}`, `Title: ${storyboard.title}`, '', storyboard.summary, '',
    '## Walkthrough', '',
    `- Video: ${fs.existsSync(finalVideo) ? finalVideo : 'not rendered'}`,
    `- Poster: ${fs.existsSync(poster) ? poster : 'not rendered'}`,
    `- Transcript: ${path.join(sessionDir, 'transcript.md')}`,
    `- Captions: ${fs.existsSync(captions) ? captions : 'not generated'}`,
    `- Storyboard: ${path.join(sessionDir, 'walkthrough.json')}`,
    '', '## Capture parity', '',
    `- Before: ${requiresBefore ? (before ? before.directory : 'missing') : `not requested — ${storyboard.baseline_reason}`}`,
    `- After: ${after ? after.directory : 'missing'}`,
    `- Readiness gates: ${readinessSatisfied ? 'satisfied for every recorded viewport' : 'not verified'}`,
    `- Viewport parity: ${viewportParity ? 'matched' : 'mismatched'}`,
    `- Before final gate: ${requiresBefore ? (beforeReadinessGate ? JSON.stringify(beforeReadinessGate) : 'missing') : 'not requested'}`,
    `- After final gate: ${afterReadinessGate ? JSON.stringify(afterReadinessGate) : 'missing'}`,
    `- Suppressed selectors: ${storyboard.suppress.length > 0 ? storyboard.suppress.map((selector) => JSON.stringify(selector)).join(', ') : 'none'}`,
    '', '## How to test', '', storyboard.how_to_test, '',
    '## PR handoff', '',
    `- Phase 5 can attach ${prInventory.attachments.length} image/video file(s) to the pull request with GitHub CLI.`,
    '- Do not commit this bundle.', '',
  ];
  if (notes.length) manifestLines.push('## Notes', '', ...notes.map((note) => `- ${note}`), '');
  fs.writeFileSync(manifest, `${manifestLines.join('\n')}\n`);

  const result = {
    version: 3,
    status,
    message: status === 'READY'
      ? `${requiresBefore ? 'Before/after' : 'After-only'} walkthrough ready (${narration.ok ? 'local narration' : 'captions only'})`
      : notes.join(' '),
    manifest,
    video: fs.existsSync(finalVideo) ? finalVideo : '',
    poster: fs.existsSync(poster) ? poster : '',
    transcript: path.join(sessionDir, 'transcript.md'),
    captions: fs.existsSync(captions) ? captions : '',
    narration: narration.ok ? 'kokoro' : (narration.incomplete ? 'failed' : 'captions-only'),
    narration_duration_seconds: narration.ok ? narration.durationSeconds : null,
    estimated_narration_seconds: narration.ok ? narration.estimatedDurationSeconds : estimatedSeconds(storyboard),
    chapter_cues: captionCues || [],
    readiness_verified: readinessSatisfied,
    readiness_gates: { before: beforeReadinessGate, after: afterReadinessGate },
    viewport_parity: viewportParity,
    viewports: { before: beforeViewports, after: afterViewports },
    suppressed_selectors: storyboard.suppress,
    before: before ? before.directory : '',
    after: after ? after.directory : '',
    duration_seconds: finalDurationSeconds,
    size_bytes: fs.existsSync(finalVideo) ? fs.statSync(finalVideo).size : 0,
    attachments: prInventory.attachments,
    attachment_fingerprint: prInventory.fingerprint,
    updated_at: new Date().toISOString(),
  };
  fs.writeFileSync(path.join(sessionDir, 'bundle.json'), `${JSON.stringify(result, null, 2)}\n`);
  return result;
}

async function produceBundle(sessionDir, storyboard, narrationEnabled) {
  try {
    return await produceBundleUnsafe(sessionDir, storyboard, narrationEnabled);
  } catch (error) {
    fs.mkdirSync(sessionDir, { recursive: true });
    const finalVideo = path.join(sessionDir, 'walkthrough.mp4');
    const poster = path.join(sessionDir, 'poster.png');
    const captions = path.join(sessionDir, 'captions.vtt');
    const manifest = path.join(sessionDir, 'visual-evidence.md');
    const reason = `Walkthrough production failed: ${String(error && error.message ? error.message : error).replace(/\s+/gu, ' ').slice(0, 1200)}`;
    fs.rmSync(finalVideo, { force: true });
    fs.rmSync(poster, { force: true });
    fs.rmSync(captions, { force: true });
    fs.rmSync(path.join(sessionDir, '.narration-chapters'), { recursive: true, force: true });
    for (const temporaryName of ['.walkthrough-concat.txt', '.walkthrough-silent.mp4', '.walkthrough-compressed.mp4']) {
      fs.rmSync(path.join(sessionDir, temporaryName), { force: true });
    }
    writeTranscript(sessionDir, storyboard);
    const manifestLines = [
      '# Visual Proof', '', 'Status: NEEDS_REVIEW', `Title: ${storyboard.title}`, '', storyboard.summary, '',
      '## Production error', '', reason, '',
      '## Editable sources', '',
      `- Storyboard: ${path.join(sessionDir, 'walkthrough.json')}`,
      `- Transcript: ${path.join(sessionDir, 'transcript.md')}`,
      '- Captions: not generated', '',
      'Raw screenshots, source videos, traces, and browser logs remain in the stage capture directories.', '',
    ];
    fs.writeFileSync(manifest, `${manifestLines.join('\n')}\n`);
    const result = {
      version: 1,
      status: 'NEEDS_REVIEW',
      message: reason,
      manifest,
      video: '',
      poster: '',
      transcript: path.join(sessionDir, 'transcript.md'),
      captions: '',
      narration: narrationEnabled ? 'failed' : 'captions-only',
      before: '',
      after: '',
      duration_seconds: null,
      size_bytes: 0,
      updated_at: new Date().toISOString(),
    };
    fs.writeFileSync(path.join(sessionDir, 'bundle.json'), `${JSON.stringify(result, null, 2)}\n`);
    return result;
  }
}

function printCapture(metadata) {
  for (const result of metadata.results) {
    console.log(`${result.viewport} screenshot: ${result.screenshot}`);
    if (result.trace) console.log(`${result.viewport} trace: ${result.trace}`);
    for (const video of result.videos) console.log(`${result.viewport} video: ${video}`);
  }
  console.log(`metadata: ${path.join(path.dirname(metadata.results[0].screenshot), 'metadata.json')}`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const storyboard = options.script ? loadStoryboard(path.resolve(options.script)) : null;
  if (options.mode === 'validate') {
    // Without this, "storyboard: valid" prints before the null storyboard
    // throws a TypeError two lines later.
    if (!storyboard) throw new Error('validate requires --script');
    console.log('storyboard: valid');
    console.log(`estimated_seconds: ${estimatedSeconds(storyboard)}`);
    console.log(`max_seconds: ${storyboard.max_seconds}`);
    return;
  }

  if (options.mode === 'capture') {
    const metadata = await captureStage(options, storyboard);
    printCapture(metadata);
    if (storyboard && options.sessionDir && options.stage === 'after') {
      const bundle = await produceBundle(options.sessionDir, storyboard, options.narration);
      console.log(`bundle: ${path.join(options.sessionDir, 'bundle.json')}`);
      console.log(`status: ${bundle.status}`);
    }
    return;
  }

  if (!storyboard || !options.sessionDir) fail('revise requires --script and --session-dir');
  const records = captureRecords(options.sessionDir);
  const revisionStages = storyboard.comparison === 'after_only' ? ['after'] : [...VALID_STAGES];
  for (const stage of revisionStages) {
    const matching = matchingStageRecord(records, stage, storyboard);
    if (matching) continue;
    const current = latestStageRecord(records, stage);
    const url = stage === 'before' ? options.beforeUrl : options.afterUrl;
    if (!url) {
      fail(current
        ? `${stage} actions changed; start that version of the app and pass --${stage}-url`
        : `${stage} capture is missing; start that version of the app and pass --${stage}-url`);
    }
    const out = path.join(options.sessionDir, `${new Date().toISOString().replace(/[:.]/g, '')}-${stage}-revision`);
    await captureStage({ ...options, mode: 'capture', stage, url, out, desktop: true, video: true }, storyboard);
  }
  const bundle = await produceBundle(options.sessionDir, storyboard, options.narration);
  console.log(`bundle: ${path.join(options.sessionDir, 'bundle.json')}`);
  console.log(`status: ${bundle.status}`);
}

module.exports = {
  generateNarration,
  loadStoryboard,
  matchingStageRecord,
  narrationDurationMatches,
  produceBundle,
  runAction,
  stageHash,
  webUrl,
  writeVtt,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  });
}
