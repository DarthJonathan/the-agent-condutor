// Real service-worker/offline browser checks against an isolated simulated relay.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

const localModules = path.resolve('frontend/node_modules');
const modules = process.env.CONDUCTOR_PLAYWRIGHT_MODULES || (existsSync(path.join(localModules, 'playwright/package.json')) ? localModules : path.join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'));
const { chromium } = createRequire(path.join(modules, 'playwright/package.json'))('playwright');
const sessions = new Set(), streams = new Set();
let account = 'one', expired = false, commands = 0, offlineBackend = false, workspaceReading = false, firstChatStatus = 'Completed';
let heldCoworkerCommand, releaseCoworkerCommand, resolveCoworkerResponse;
const coworkerResponse = new Promise(resolve => { resolveCoworkerResponse = resolve; });
const user = () => ({ id: account, email: `${account}@example.test` });
const run = id => ({ run_id: id, workspace_id: 'workspace', generation: 'generation', version: 1,
  run: { title: `Fixture chat ${id}`, created_at: id, status: id === 'one' ? firstChatStatus : 'Completed', conversation: {
    coworkers: [{ id: 'maya', name: 'Maya', mention: 'maya', provider: 'codex', effort: 'default', can_read_workspace: workspaceReading }],
    messages: [{ id: `${id}-reply`, author_id: 'maya', kind: 'assistant', status: 'Completed', text: `# Saved reply ${id}\n\n| Agent | Status |\n| --- | --- |\n| Maya | Ready |` },
      { id: `${id}-question`, kind: 'assistant', question_request: { id: 'question', questions: [{ id: 'q', question: 'Which scope?', options: [{ id: 'a', label: 'Review it' }] }] },
        approval_request: { id: 'approval', summary: 'Fixture operation', argv: ['fixture'] } }]
  } }
});
function snapshot(selected) {
  return { device: { id: 'mac', name: 'Fixture Mac', last_seen: new Date().toISOString() }, workspaces: [{ id: 'workspace', label: 'Fixture project' }],
    connections: [{ provider: 'codex', available: true, snippets_only: true }], commands: [],
    runs: ['one', 'two'].map(id => id === selected ? run(id) : { ...run(id), summary: true, run: { title: `Fixture chat ${id}`, created_at: id } }) };
}
const backend = http.createServer(async (request, response) => {
  const url = new URL(request.url, 'http://fixture');
  const reply = (data, status = 200, headers = {}) => { response.writeHead(status, { 'content-type': 'application/json', ...headers }); response.end(JSON.stringify(data)); };
  if (offlineBackend) return reply({ error: 'Fixture relay unavailable' }, 503);
  if (url.pathname.endsWith('/auth/options')) return reply({ signup_enabled: false });
  if (url.pathname.endsWith('/auth/login')) {
    let body = ''; for await (const chunk of request) body += chunk;
    assert.equal(JSON.parse(body).password, 'fixture-password-1234');
    sessions.add('fixture-session'); expired = false;
    return reply({ user: user(), csrf: 'fixture-csrf-secret' }, 200, { 'set-cookie': 'conductor-session=fixture-session; Path=/; HttpOnly; SameSite=Strict' });
  }
  if (expired || !sessions.has('fixture-session') || !request.headers.cookie?.includes('fixture-session')) return reply({ error: 'Sign in required' }, 401);
  if (url.pathname.endsWith('/auth/session')) return reply({ user: user(), csrf: 'fixture-csrf-secret' });
  if (url.pathname.endsWith('/auth/logout')) { sessions.clear(); return reply({ ok: true }); }
  if (url.pathname === '/api/v1/devices') return reply({ devices: [snapshot().device] });
  if (url.pathname === '/api/v1/events') {
    response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
    response.write(`event: snapshot\ndata: ${JSON.stringify(snapshot(url.searchParams.get('run_id')))}\n\n`);
    streams.add(response); request.on('close', () => streams.delete(response)); return;
  }
  if (url.pathname.includes('/commands')) {
    let body = ''; for await (const chunk of request) body += chunk;
    const command = JSON.parse(body); commands++;
    if (command.kind === 'coworker') {
      heldCoworkerCommand = command;
      await new Promise(resolve => { releaseCoworkerCommand = resolve; });
    }
    reply({ id: 'command', status: 'queued' });
    if (command.kind === 'coworker') resolveCoworkerResponse();
    return;
  }
  if (url.pathname === '/api/v1/devices/mac') return reply(snapshot(url.searchParams.get('run_id')));
  reply({ error: `Unexpected fixture route ${url.pathname}` }, 404);
});
await new Promise(resolve => backend.listen(0, '127.0.0.1', resolve));
const backendOrigin = `http://127.0.0.1:${backend.address().port}`;
const probe = net.createServer(); await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ['build'], { cwd: path.resolve('frontend'), env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), ORIGIN: origin, NODE_ENV: 'production', BACKEND_API_URL: backendOrigin }, stdio: ['ignore', 'pipe', 'pipe'] });
let browser, log = '';
for (const output of [server.stdout, server.stderr]) output.on('data', chunk => log = (log + chunk).slice(-4000));
const history = page => page.evaluate(() => new Promise((resolve, reject) => {
  const request = indexedDB.open('conductor-offline', 1);
  request.onsuccess = () => { const db = request.result, tx = db.transaction('state'); const read = tx.objectStore('state').get('history'); read.onsuccess = () => { db.close(); resolve(read.result || null); }; read.onerror = () => reject(read.error); };
  request.onerror = () => reject(request.error);
}));
async function saved(page) { await page.waitForFunction(() => document.querySelector('.offline-tools')?.textContent.includes('Clear offline copy')); }
async function restoreConnection(context, page, selector) {
  await context.setOffline(false);
  // Restoring emulated transport can race the online event in Chromium.
  // Exercise the app's recovery button if the first connectivity check failed.
  await page.waitForFunction(selector => {
    const field = document.querySelector(selector);
    return (field && !field.disabled) || [...document.querySelectorAll('button')].some(button => button.textContent.trim() === 'Reconnect' && !button.disabled);
  }, selector);
  await page.evaluate(() => {
    const retry = [...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Reconnect' && !button.disabled);
    retry?.click();
  });
  await page.waitForFunction(selector => {
    const field = document.querySelector(selector);
    return field && !field.disabled;
  }, selector);
}
try {
  let ready = false;
  for (let i = 0; i < 100; i++) { try { ready = (await fetch(origin)).ok; } catch {} if (ready) break; if (server.exitCode !== null) throw new Error(log); await new Promise(resolve => setTimeout(resolve, 50)); }
  assert(ready, log);
  const executablePath = process.env.CONDUCTOR_CHROMIUM_EXECUTABLE || chromium.executablePath();
  assert(existsSync(executablePath), 'Install the pinned browser with frontend/node_modules/.bin/playwright install chromium, or explicitly set CONDUCTOR_CHROMIUM_EXECUTABLE.');
  browser = await chromium.launch({ headless: true, executablePath });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin); await page.getByRole('button', { name: 'Sign in', exact: true }).waitFor();
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.waitForFunction(() => !!navigator.serviceWorker.controller);
  const manifest = await page.evaluate(async () => (await fetch('/manifest.webmanifest')).json());
  assert.equal(manifest.display, 'standalone'); assert.equal(manifest.start_url, '/');
  assert.deepEqual(manifest.icons.map(i => i.sizes), ['192x192', '512x512']);
  for (const icon of manifest.icons) assert.equal(await page.evaluate(src => new Promise(resolve => { const img = new Image(); img.onload = () => resolve(img.naturalWidth); img.src = src; }), icon.src), Number(icon.sizes.split('x')[0]));
  await page.getByRole('button', { name: 'Install app', exact: true }).click();
  await page.getByText('On iPhone or iPad,', { exact: false }).waitFor();
  await context.setOffline(true); await page.reload();
  await page.getByText('You’re offline', { exact: true }).waitFor();
  assert(await page.getByRole('button', { name: 'Sign in', exact: true }).isDisabled());
  assert.equal(await history(page), null);
  await restoreConnection(context, page, 'form button.primary');
  async function login() {
    await page.getByLabel('Email', { exact: true }).fill(`${account}@example.test`);
    await page.getByLabel('Password', { exact: true }).fill('fixture-password-1234');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.getByRole('button', { name: 'Fixture chat one', exact: true }).waitFor();
  }
  await login(); await page.getByRole('button', { name: 'Fixture chat one', exact: true }).click();
  await page.getByRole('heading', { name: 'Saved reply one', exact: true }).waitFor();
  // A queued grant must never leave an old access value in the control when an
  // earlier engine snapshot confirms the change before the queue response.
  const access = page.getByLabel('Maya can read workspace', { exact: true });
  assert.equal(await access.isChecked(), false);
  await access.click();
  for (let i = 0; i < 100 && !heldCoworkerCommand; i++) await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(heldCoworkerCommand?.payload?.can_read_workspace, true);
  assert.equal(await access.isChecked(), false, 'Pending access commands must keep the engine snapshot value');
  workspaceReading = true;
  for (const response of streams) response.write(`event: snapshot\ndata: ${JSON.stringify(snapshot('one'))}\n\n`);
  await page.waitForFunction(() => document.querySelector('[aria-label="Maya can read workspace"]')?.checked === true);
  releaseCoworkerCommand?.();
  await coworkerResponse;
  await page.getByText('Queued for your Mac.', { exact: true }).waitFor();
  assert.equal(await access.isChecked(), true, 'A delayed queue response must not overwrite the confirmed engine update');
  // Cache a running conversation for the later offline Stop agents control check.
  firstChatStatus = 'Running';
  for (const response of streams) response.write(`event: snapshot\ndata: ${JSON.stringify(snapshot('one'))}\n\n`);
  await page.getByRole('button', { name: 'Stop agents', exact: true }).waitFor();
  commands = 0;
  assert.equal(await history(page), null, 'Chat content must be opt-in');
  await page.getByLabel('Save chats offline', { exact: true }).check(); await saved(page);
  await page.getByRole('button', { name: 'Fixture chat two', exact: true }).click();
  await page.getByRole('heading', { name: 'Saved reply two', exact: true }).waitFor();
  for (let i = 0; i < 100; i++) { const copy = await history(page); if (copy?.selectedRun === 'two' && copy.devices[0].runs.filter(r => r.run.conversation).length === 2) break; await new Promise(resolve => setTimeout(resolve, 50)); }
  const stored = await history(page);
  assert.equal(stored.devices[0].runs.filter(r => r.run.conversation).length, 2, `Previously opened transcripts survive summaries: ${JSON.stringify(stored.devices[0].runs.map(r => ({ id: r.run_id, summary: r.summary, full: !!r.run.conversation })))}`);
  assert(!JSON.stringify(stored).includes('fixture-csrf-secret')); assert(!JSON.stringify(stored).includes('fixture-password-1234'));
  const cacheEntries = await page.evaluate(async () => { const keys = []; for (const name of await caches.keys()) for (const request of await (await caches.open(name)).keys()) keys.push(new URL(request.url).pathname); return keys; });
  assert(cacheEntries.includes('/')); assert(!cacheEntries.some(key => key.startsWith('/api/')));
  assert(await page.evaluate(async () => { const cache = await caches.open((await caches.keys()).find(name => name.startsWith('conductor-shell-'))); const response = await cache.match('/'); return response.headers.get('content-security-policy')?.includes("frame-ancestors 'none'") && !(await response.text()).includes('one@example.test'); }), 'Cached anonymous shell must preserve its CSP headers');
  await context.setOffline(true); await page.reload();
  await page.getByText('Offline · read-only', { exact: true }).waitFor();
  await page.getByRole('heading', { name: 'Saved reply two', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Fixture chat one', exact: true }).click();
  await page.getByRole('heading', { name: 'Saved reply one', exact: true }).waitFor();
  assert.equal(await page.locator('.markdown table tbody tr').count(), 1);
  for (const label of ['Message', 'Maya model', 'Maya effort', 'Custom answer']) assert(await page.getByLabel(label, { exact: true }).isDisabled(), `${label} must be read-only offline`);
  for (const name of ['Send ↗', 'Stop agents', 'Approve', 'Decline', 'Send answers', 'Disconnect this computer', 'Sign out']) assert(await page.getByRole('button', { name, exact: true }).isDisabled(), `${name} must be disabled offline`);
  assert.equal(commands, 0, 'Offline actions must never queue commands');
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Offline UI overflows on mobile');
  const output = path.resolve('target/remote-web'); await mkdir(output, { recursive: true });
  assert.equal(await page.locator('.app').count(), 1);
  await page.locator('.workspace').screenshot({ path: path.join(output, 'pwa-offline.png') });
  await restoreConnection(context, page, 'textarea[aria-label="Message"]');
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.getByRole('button', { name: 'Sign in', exact: true }).waitFor(); assert.equal(await history(page), null);
  // Cached history is discarded when a live session is rejected or belongs to another account.
  await login(); await page.getByRole('button', { name: 'Fixture chat one', exact: true }).click(); await page.getByRole('heading', { name: 'Saved reply one', exact: true }).waitFor();
  await page.getByLabel('Save chats offline', { exact: true }).check(); await saved(page);
  account = 'two'; await page.reload(); await page.getByText('two@example.test', { exact: true }).waitFor();
  assert.equal(await history(page), null); assert(!(await page.getByLabel('Save chats offline', { exact: true }).isChecked()));
  await page.getByLabel('Save chats offline', { exact: true }).check(); await saved(page);
  expired = true; await page.reload(); await page.getByRole('button', { name: 'Sign in', exact: true }).waitFor(); assert.equal(await history(page), null);
  expired = false; await login(); await page.getByLabel('Save chats offline', { exact: true }).check(); await saved(page);
  offlineBackend = true; for (const response of streams) response.destroy(); await page.reload();
  await page.getByText('Offline · read-only', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Clear offline copy', exact: true }).click(); assert.equal(await history(page), null);
  await page.reload(); await page.getByText('You’re offline', { exact: true }).waitFor();
  assert.equal(await page.evaluate(() => localStorage.length), 0);
  const sessionData = await page.evaluate(() => JSON.stringify(Object.entries(sessionStorage)));
  for (const secret of ['fixture-csrf-secret', 'fixture-password-1234', 'fixture-session', 'one@example.test', 'two@example.test']) assert(!sessionData.includes(secret), 'Browser session storage must not contain credentials or account data');
  assert.deepEqual(errors, []);
  console.log('PASS: install metadata/icons, real service worker, offline reload, opt-in bounded history, read-only controls, reconnect, account change, session expiry, sign-out and clearing');
  console.log('Preview: target/remote-web/pwa-offline.png');
} finally {
  releaseCoworkerCommand?.();
  await browser?.close(); server.kill('SIGTERM');
  for (const response of streams) response.destroy();
  backend.closeAllConnections(); await new Promise(resolve => backend.close(resolve));
}
