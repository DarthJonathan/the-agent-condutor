// A disposable account and simulated device exercise the real browser UI and HTTP proxy.
// Uses an installed Playwright package; no coding-provider calls or desktop state.
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

const modules = process.env.CONDUCTOR_PLAYWRIGHT_MODULES || path.join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules');
const { chromium } = createRequire(path.join(modules, 'playwright/package.json'))('playwright');
const origin = process.env.CONDUCTOR_TEST_ORIGIN || 'http://localhost:3005';
const email = `${randomUUID()}@example.test`, password = randomBytes(24).toString('base64url');
let cookie = '', csrf = '', token = '', device = '', browser;
async function api(route, method = 'GET', body, bearer = false) {
  const response = await fetch(`${origin}/api/v1${route}`, {
    method, headers: { 'content-type': 'application/json', origin, ...(bearer ? { authorization: `Bearer ${token}` } : { cookie, 'x-csrf-token': csrf }) },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const data = await response.json();
  assert(response.ok, `${route}: ${response.status} ${data.error || ''}`);
  if (response.headers.has('set-cookie')) cookie = response.headers.get('set-cookie').split(';')[0];
  return data;
}
async function nextCommand(kind) {
  const claimed = await api('/device/commands', 'GET', undefined, true);
  assert.equal(claimed.commands.length, 1);
  const command = claimed.commands[0]; assert.equal(command.kind, kind);
  await api(`/device/commands/${command.id}/ack`, 'POST', { status: 'delivered', result: 'Browser fixture accepted' }, true);
  return command.payload;
}
try {
  csrf = (await api('/auth/register', 'POST', { email, password })).csrf;
  const workspace = randomUUID(), runID = randomUUID(), generation = randomUUID(), workerID = randomUUID(), messageID = randomUUID(), questionID = randomUUID(), requestID = randomUUID();
  const enrolled = await api('/devices', 'POST', { name: 'Browser fixture Mac', workspaces: [{ id: workspace, label: 'Fixture project' }] });
  device = enrolled.device.id; token = enrolled.token;
  await api('/device/workspaces', 'PUT', { workspaces: [{ id: workspace, label: 'Fixture project' }], connections: [{ provider: 'codex', model: '', effort: 'default', available: true }] }, true);
  const run = {
    id: runID, workspace, title: 'Browser fixture conversation', prompt: 'Browser fixture conversation', workflow: 'Chat', status: 'WaitingForUser', created_at: new Date().toISOString(),
    conversation: { coworkers: [{ id: workerID, name: 'Maya', mention: 'maya', provider: 'codex', role: 'Builder', model: '', effort: 'default', attention: 'needs_user' }],
      messages: [{ id: randomUUID(), author_id: workerID, kind: 'assistant', status: 'Completed', text: '# A proper table\n\n| Coworker | Status |\n| --- | --- |\n| Maya | Ready |\n\n```rust\n' + 'let value = 1; '.repeat(90) + '\n```\n<img src="https://invalid.example/tracker" onerror="alert(1)"><script>alert(2)</script>' },
        { id: messageID, author_id: workerID, kind: 'assistant', status: 'WaitingForUser', text: 'Please choose a fixture scope.', question_request: { id: requestID, answers: null, questions: [{ id: questionID, question: 'Which parts should Maya check?', multi_select: true, options: [{ id: 'alpha', label: 'Alpha' }, { id: 'beta', label: 'Beta' }] }] } }], mailbox: [] },
    changes: { files: [{ path: 'fixture.rs', diff: '+let value = 1;' }], checks: [{ status: 'passed', output: 'Fixture test passed' }] }
  };
  await api('/device/events', 'POST', { kind: 'run_snapshot', run_id: runID, workspace_id: workspace, generation, version: 1, run }, true);
  browser = await chromium.launch({ headless: true, executablePath: process.env.CONDUCTOR_CHROMIUM_EXECUTABLE || undefined });
  const context = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  const page = await context.newPage(); const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin);
  await page.getByLabel('Email', { exact: true }).fill(email);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.getByRole('button', { name: 'Browser fixture conversation', exact: true }).click();
  await page.getByRole('heading', { name: 'A proper table' }).waitFor();
  assert.equal(await page.locator('.markdown table tbody tr').count(), 1);
  assert.equal(await page.locator('.markdown img, .markdown script').count(), 0);
  const cookies = await context.cookies(); assert(cookies.some(c => c.httpOnly && c.sameSite === 'Strict' && c.name.includes('conductor-session')));
  assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0);
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await message.fill('@m');
  await page.getByRole('listbox', { name: 'Mention a coworker' }).waitFor();
  await message.press('Tab'); assert.equal(await message.inputValue(), '@maya ');
  await message.fill('@maya Check this fixture');
  await page.getByRole('button', { name: 'Send ↗', exact: true }).click();
  assert.equal((await nextCommand('message')).prompt, '@maya Check this fixture');
  await page.getByLabel('Maya model', { exact: true }).fill('fixture-model');
  await page.getByLabel('Maya model', { exact: true }).press('Tab');
  assert.equal((await nextCommand('coworker')).model, 'fixture-model');
  await page.getByLabel('Maya effort', { exact: true }).selectOption('high');
  assert.equal((await nextCommand('coworker')).effort, 'high');
  await page.getByLabel('Alpha', { exact: true }).check(); await page.getByLabel('Beta', { exact: true }).check();
  await page.getByRole('button', { name: 'Send answers', exact: true }).click();
  const answers = await nextCommand('answer'); assert.equal(answers.request_id, requestID); assert.deepEqual(answers.answers[0].option_ids, ['alpha','beta']);
  await page.locator('summary').filter({ hasText: 'Checks' }).click(); await page.getByText('Fixture test passed', { exact: true }).waitFor();
  // Live updates use plain text; completed responses become sanitized Markdown.
  await api('/device/events', 'POST', { kind: 'run_patch', run_id: runID, workspace_id: workspace, generation, base_version: 1, version: 2, changes: [{ op: 'set', path: ['conversation','messages','0','status'], value: 'Running' }] }, true);
  await page.locator('article .live').first().waitFor();
  await api('/device/events', 'POST', { kind: 'run_patch', run_id: runID, workspace_id: workspace, generation, base_version: 2, version: 3, changes: [{ op: 'append', path: ['conversation','messages','0','text'], value: '\nLive tail 🦀' }] }, true);
  await page.getByText('Live tail 🦀', { exact: false }).waitFor();
  await api('/device/events', 'POST', { kind: 'run_patch', run_id: runID, workspace_id: workspace, generation, base_version: 3, version: 4, changes: [{ op: 'set', path: ['conversation','messages','0','status'], value: 'Completed' }] }, true);
  await page.getByRole('heading', { name: 'A proper table' }).waitFor();
  const output = path.resolve('target/remote-web'); await mkdir(output, { recursive: true });
  await page.locator('.transcript').evaluate(node => { node.scrollTop = 0; });
  await page.screenshot({ path: path.join(output, 'desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile page overflows horizontally');
  await page.screenshot({ path: path.join(output, 'mobile.png'), fullPage: true });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.getByRole('button', { name: 'Sign in', exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log('PASS: browser login/logout, secure cookie storage, Markdown sanitization/tables, mentions, model/effort commands, multi-select answers, live patches, checks and mobile width');
  console.log(`Screenshots: ${output}`);
} finally {
  await browser?.close();
  if (device) await api(`/devices/${device}`, 'DELETE');
  if (cookie) await api('/auth/logout', 'POST', {});
}
