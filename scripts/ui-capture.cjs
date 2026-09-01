#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { spawnSync } = require('child_process');

const ALLOWED_ACTIONS = new Set([
  'goto', 'click', 'fill', 'press', 'hover', 'scroll', 'wait', 'assert', 'screenshot',
]);
const ALLOWED_LOCATORS = new Set(['role', 'label', 'text', 'testid']);
const VALID_STAGES = new Set(['before', 'after']);

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
      case '--mobile': options.mobile = true; break;
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
  if (!ALLOWED_LOCATORS.has(locator.by)) {
    fail(`${label}.locator.by must be role, label, text, or testid`);
  }
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
  if (['click', 'fill', 'hover', 'scroll', 'assert'].includes(action.action) && action.locator) {
    validateLocator(action.locator, label);
  } else if (['click', 'fill', 'hover', 'assert'].includes(action.action)) {
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
  if (action.action === 'scroll' && !action.locator) {
    if (!Number.isInteger(action.y) || Math.abs(action.y) > 5000) {
      fail(`${label}.y must be an integer between -5000 and 5000`);
    }
  }
  if (action.action === 'screenshot') requiredString(action.name, `${label}.name`, 120);
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
  const transcriptSeconds = estimatedSeconds(value);
  if (transcriptSeconds > value.max_seconds) {
    fail(`storyboard narration is approximately ${transcriptSeconds}s and exceeds max_seconds ${value.max_seconds}`);
  }
  return value;
}

function narrationText(storyboard) {
  return storyboard.chapters.map((chapter) => chapter.narration.trim()).join(' ');
}

function estimatedSeconds(storyboard) {
  const words = narrationText(storyboard).split(/\s+/u).filter(Boolean).length;
  return Math.max(1, Math.ceil((words / 150) * 60));
}

function stableHash(value) {
  return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

function stageHash(storyboard, stage) {
  return stableHash(storyboard.chapters.filter((chapter) => chapter.stage === stage));
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
    if (!/networkidle|Navigation timeout/i.test(String(error && error.message))) throw error;
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
  }
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

async function runStoryboardStage({ page, options, storyboard, viewportName, outDir }) {
  const chapters = storyboard.chapters.filter((chapter) => chapter.stage === options.stage);
  for (const chapter of chapters) {
    let chapterShown = false;
    for (const action of chapter.actions) {
      if (action.action !== 'goto' && !chapterShown) {
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
        await showChapter(page, chapter);
        chapterShown = true;
      }
    }
  }
}

async function runViewport({ browser, playwright, options, storyboard, viewportName, viewport }) {
  const outDir = options.out;
  const videoDir = path.join(outDir, 'video', viewportName);
  const contextOptions = { viewport, deviceScaleFactor: 1, ignoreHTTPSErrors: true };
  if (viewportName === 'mobile') Object.assign(contextOptions, playwright.devices['iPhone 15']);
  if (options.video || storyboard) {
    fs.mkdirSync(videoDir, { recursive: true });
    contextOptions.recordVideo = { dir: videoDir, size: viewport };
  }

  const context = await browser.newContext(contextOptions);
  const tracePath = path.join(outDir, `${viewportName}-trace.zip`);
  if (options.trace || storyboard) await context.tracing.start({ screenshots: true, snapshots: true, sources: true });

  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  const networkErrors = [];
  const responses = [];
  page.on('console', (message) => { if (['error', 'warning'].includes(message.type())) consoleErrors.push(`[${message.type()}] ${message.text()}`); });
  page.on('pageerror', (error) => pageErrors.push(error.stack || error.message || String(error)));
  page.on('requestfailed', (request) => networkErrors.push(`${request.method()} ${request.url()} :: ${(request.failure() || {}).errorText || 'failed'}`));
  page.on('response', (response) => { if (response.status() >= 400) responses.push(`${response.status()} ${response.url()}`); });

  await safeGoto(page, options.url);
  await ensureOverlay(page, options.stage || 'capture');
  if (options.waitMs > 0) await page.waitForTimeout(options.waitMs);

  if (storyboard) {
    await runStoryboardStage({ page, options, storyboard, viewportName, outDir });
  } else if (options.flow) {
    const flowPath = path.resolve(options.flow);
    const flow = require(flowPath);
    const runner = typeof flow === 'function' ? flow : flow.run;
    if (typeof runner !== 'function') fail(`Flow file must export a function or { run }; got ${flowPath}`);
    await runner({
      page, context, viewportName, artifactsDir: outDir,
      screenshot: async (name) => {
        const screenshotPath = path.join(outDir, `${viewportName}-${slugify(name)}.png`);
        await page.screenshot({ path: screenshotPath, fullPage: true });
        return screenshotPath;
      },
    });
  }

  if (options.waitMs > 0) await page.waitForTimeout(options.waitMs);
  const screenshotPath = path.join(outDir, `${viewportName}.png`);
  await page.screenshot({ path: screenshotPath, fullPage: !storyboard });
  if (options.trace || storyboard) await context.tracing.stop({ path: tracePath });
  await context.close();

  const videoFiles = fs.existsSync(videoDir)
    ? fs.readdirSync(videoDir).filter((file) => file.endsWith('.webm')).map((file) => path.join(videoDir, file))
    : [];
  return { viewport: viewportName, screenshot: screenshotPath, trace: options.trace || storyboard ? tracePath : null, videos: videoFiles, consoleErrors, pageErrors, networkErrors, httpErrors: responses };
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
    version: 2,
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
  const result = record.results.find((candidate) => candidate.viewport === 'desktop') || record.results[0];
  return result && result.videos && result.videos.find((video) => fs.existsSync(video));
}

function writeTranscript(sessionDir, storyboard, mediaSeconds = null) {
  const lines = [
    `# ${storyboard.title}`, '', storyboard.summary, '',
    '## Product context', '', storyboard.product_context, '',
    '## Technical summary', '', storyboard.technical_summary, '',
    '## How to test', '', storyboard.how_to_test, '',
    '## Transcript', '',
  ];
  storyboard.chapters.forEach((chapter) => {
    const stage = chapter.stage === 'before' ? 'Before' : 'After';
    const title = chapter.title.trim();
    const heading = title.toLowerCase() === stage.toLowerCase() || title.toLowerCase().startsWith(`${stage.toLowerCase()}:`)
      ? title
      : `${stage}: ${title}`;
    lines.push(`### ${heading}`, '', chapter.narration, '');
  });
  fs.writeFileSync(path.join(sessionDir, 'transcript.md'), `${lines.join('\n')}\n`);

  const total = mediaSeconds === null
    ? Math.max(estimatedSeconds(storyboard), storyboard.target_seconds)
    : Math.max(1, mediaSeconds);
  const duration = total / storyboard.chapters.length;
  const vtt = ['WEBVTT', ''];
  const timecode = (seconds) => {
    const totalMilliseconds = Math.max(0, Math.round(seconds * 1000));
    const hours = String(Math.floor(totalMilliseconds / 3600000)).padStart(2, '0');
    const minutes = String(Math.floor((totalMilliseconds % 3600000) / 60000)).padStart(2, '0');
    const secs = String(Math.floor((totalMilliseconds % 60000) / 1000)).padStart(2, '0');
    const milliseconds = String(totalMilliseconds % 1000).padStart(3, '0');
    return `${hours}:${minutes}:${secs}.${milliseconds}`;
  };
  storyboard.chapters.forEach((chapter, index) => {
    vtt.push(`${timecode(index * duration)} --> ${timecode((index + 1) * duration)}`, chapter.narration, '');
  });
  fs.writeFileSync(path.join(sessionDir, 'captions.vtt'), `${vtt.join('\n')}\n`);
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

async function generateNarration(sessionDir, storyboard) {
  const toolsDir = process.env.DX_UI_CAPTURE_TOOLS_DIR;
  if (!toolsDir) return { ok: false, reason: 'tool directory is unavailable' };
  try {
    const packagePath = require.resolve('kokoro-js', { paths: [toolsDir] });
    const { KokoroTTS } = await import(pathToFileURL(packagePath).href);
    const tts = await KokoroTTS.from_pretrained('onnx-community/Kokoro-82M-v1.0-ONNX', { dtype: 'q8', device: 'cpu' });
    const audio = await tts.generate(narrationText(storyboard), { voice: process.env.DX_UI_CAPTURE_VOICE || 'bf_emma', speed: 1.05 });
    const output = path.join(sessionDir, 'narration.wav');
    await audio.save(output);
    return { ok: fs.existsSync(output) && fs.statSync(output).size > 0, path: output, reason: 'local Kokoro narration failed' };
  } catch (error) {
    return { ok: false, reason: String(error && error.message ? error.message : error) };
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
  fs.rmSync(finalVideo, { force: true });
  fs.rmSync(poster, { force: true });
  const notes = [];
  let status = 'READY';
  let narration = { ok: false, reason: 'disabled' };
  let finalDurationSeconds = null;

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
      if (narrationEnabled) narration = await generateNarration(sessionDir, storyboard);
      if (narration.ok) {
        const silentDuration = mediaDuration(binary, silentVideo);
        const narrationDuration = mediaDuration(binary, narration.path);
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
        notes.push(narrationEnabled
          ? `Local narration unavailable; the captioned video is ready (${narration.reason}).`
          : 'Narration was disabled; the captioned video is ready.');
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
    }
  }

  if (finalDurationSeconds !== null) writeTranscript(sessionDir, storyboard, finalDurationSeconds);

  const afterResult = after && (after.results.find((item) => item.viewport === 'desktop') || after.results[0]);
  if (afterResult && afterResult.screenshot && fs.existsSync(afterResult.screenshot)) fs.copyFileSync(afterResult.screenshot, poster);

  const manifestLines = [
    '# Visual Proof', '', `Status: ${status}`, `Title: ${storyboard.title}`, '', storyboard.summary, '',
    '## Walkthrough', '',
    `- Video: ${fs.existsSync(finalVideo) ? finalVideo : 'not rendered'}`,
    `- Poster: ${fs.existsSync(poster) ? poster : 'not rendered'}`,
    `- Transcript: ${path.join(sessionDir, 'transcript.md')}`,
    `- Captions: ${path.join(sessionDir, 'captions.vtt')}`,
    `- Storyboard: ${path.join(sessionDir, 'walkthrough.json')}`,
    '', '## Capture parity', '',
    `- Before: ${requiresBefore ? (before ? before.directory : 'missing') : `not requested — ${storyboard.baseline_reason}`}`,
    `- After: ${after ? after.directory : 'missing'}`,
    '', '## How to test', '', storyboard.how_to_test, '',
    '## PR handoff', '',
    '- Upload the MP4 and poster to the pull request by dragging them into the PR body or a comment.',
    '- Do not commit this bundle.', '',
  ];
  if (notes.length) manifestLines.push('## Notes', '', ...notes.map((note) => `- ${note}`), '');
  fs.writeFileSync(manifest, `${manifestLines.join('\n')}\n`);

  const result = {
    version: 1,
    status,
    message: status === 'READY'
      ? `${requiresBefore ? 'Before/after' : 'After-only'} walkthrough ready (${narration.ok ? 'local narration' : 'captions only'})`
      : notes.join(' '),
    manifest,
    video: fs.existsSync(finalVideo) ? finalVideo : '',
    poster: fs.existsSync(poster) ? poster : '',
    transcript: path.join(sessionDir, 'transcript.md'),
    captions: path.join(sessionDir, 'captions.vtt'),
    narration: narration.ok ? 'kokoro' : 'captions-only',
    before: before ? before.directory : '',
    after: after ? after.directory : '',
    duration_seconds: finalDurationSeconds,
    size_bytes: fs.existsSync(finalVideo) ? fs.statSync(finalVideo).size : 0,
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
    const manifest = path.join(sessionDir, 'visual-evidence.md');
    const reason = `Walkthrough production failed: ${String(error && error.message ? error.message : error).replace(/\s+/gu, ' ').slice(0, 1200)}`;
    fs.rmSync(finalVideo, { force: true });
    fs.rmSync(poster, { force: true });
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
      `- Captions: ${path.join(sessionDir, 'captions.vtt')}`, '',
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
      captions: path.join(sessionDir, 'captions.vtt'),
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
    await captureStage({ ...options, mode: 'capture', stage, url, out, desktop: true, video: true, trace: true }, storyboard);
  }
  const bundle = await produceBundle(options.sessionDir, storyboard, options.narration);
  console.log(`bundle: ${path.join(options.sessionDir, 'bundle.json')}`);
  console.log(`status: ${bundle.status}`);
}

module.exports = {
  loadStoryboard,
  matchingStageRecord,
  produceBundle,
  stageHash,
  webUrl,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  });
}
