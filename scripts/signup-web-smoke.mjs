// Exercise the built signup UI against controlled API responses, without real accounts.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';

const localModules = path.resolve('frontend/node_modules');
const modules = process.env.CONDUCTOR_PLAYWRIGHT_MODULES || (existsSync(path.join(localModules, 'playwright/package.json')) ? localModules : path.join(process.env.HOME, '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules'));
const { chromium } = createRequire(path.join(modules, 'playwright/package.json'))('playwright');
const probe = net.createServer();
await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ['build'], {
  cwd: path.resolve('frontend'),
  env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), ORIGIN: origin, NODE_ENV: 'production', BACKEND_API_URL: 'http://127.0.0.1:9' },
  stdio: ['ignore', 'pipe', 'pipe']
});
let log = '', browser;
for (const output of [server.stdout, server.stderr]) output.on('data', chunk => log = (log + chunk).slice(-4000));
try {
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try { ready = (await fetch(origin)).ok; } catch {}
    if (ready) break;
    if (server.exitCode !== null) throw new Error(`Fixture server exited: ${log}`);
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert(ready, `Fixture server did not start: ${log}`);
  const executablePath = process.env.CONDUCTOR_CHROMIUM_EXECUTABLE || chromium.executablePath();
  assert(existsSync(executablePath), 'Install the pinned browser with frontend/node_modules/.bin/playwright install chromium, or explicitly set CONDUCTOR_CHROMIUM_EXECUTABLE.');
  browser = await chromium.launch({ headless: true, executablePath });
  for (const allowed of [false, true]) {
    const context = await browser.newContext({ viewport: { width: 900, height: 800 }, serviceWorkers: 'block' });
    const page = await context.newPage(), errors = [];
    page.on('pageerror', error => errors.push(error.message));
    let attempts = 0, signedIn = false, release;
    const pending = new Promise(resolve => release = resolve);
    const credentials = { email: 'signup-fixture@example.test', password: 'fixture-password-1234' };
    await page.route(`${origin}/api/v1/**`, async route => {
      const request = route.request(), endpoint = new URL(request.url()).pathname;
      const reply = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
      if (endpoint === '/api/v1/auth/options') return reply({ signup_enabled: allowed });
      if (endpoint === '/api/v1/auth/session') return reply({ error: 'sign in required' }, 401);
      if (endpoint === '/api/v1/auth/register') {
        assert(allowed); assert.equal(request.method(), 'POST'); assert.deepEqual(request.postDataJSON(), credentials);
        if (++attempts === 1) { await pending; return reply({ error: 'Fixture signup failed' }, 400); }
        signedIn = true;
        return reply({ user: { id: 'signup-fixture', email: credentials.email }, csrf: 'fixture-csrf', signup_enabled: true });
      }
      if (endpoint === '/api/v1/devices') { assert(signedIn); return reply({ devices: [] }); }
      if (endpoint === '/api/v1/auth/logout') { signedIn = false; return reply({ ok: true }); }
      throw new Error(`Unexpected fixture request: ${endpoint}`);
    });
    await page.goto(origin, { waitUntil: 'networkidle' });
    const toggle = page.getByRole('button', { name: 'Create an account', exact: true });
    if (!allowed) {
      assert.equal(await toggle.count(), 0);
      assert(await page.getByRole('button', { name: 'Sign in', exact: true }).isVisible());
    } else {
      await toggle.click();
      await page.getByRole('heading', { name: 'Create your account', exact: true }).waitFor();
      assert.equal(await page.getByLabel('Password', { exact: true }).getAttribute('autocomplete'), 'new-password');
      const output = path.resolve('target/remote-web'); await mkdir(output, { recursive: true });
      await page.locator('.login-card').screenshot({ path: path.join(output, 'signup.png') });
      await page.setViewportSize({ width: 390, height: 844 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Signup overflows on mobile');
      await page.getByLabel('Email', { exact: true }).fill(credentials.email);
      await page.getByLabel('Password', { exact: true }).fill(credentials.password);
      await page.getByRole('button', { name: 'Create account', exact: true }).click();
      await page.getByRole('button', { name: 'Creating account…', exact: true }).waitFor();
      assert(await page.getByLabel('Email', { exact: true }).isDisabled());
      assert(await page.getByLabel('Password', { exact: true }).isDisabled());
      assert(await page.getByRole('button', { name: 'Back to sign in', exact: true }).isDisabled());
      release();
      await page.getByRole('alert').filter({ hasText: 'Fixture signup failed' }).waitFor();
      await page.getByRole('button', { name: 'Create account', exact: true }).click();
      await page.getByRole('button', { name: 'Sign out', exact: true }).waitFor();
      await page.getByRole('button', { name: 'Sign out', exact: true }).click();
      await page.getByRole('button', { name: 'Sign in', exact: true }).waitFor();
      assert.equal(await page.getByRole('heading', { name: 'Create your account', exact: true }).count(), 0);
      assert.equal(attempts, 2);
      assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0);
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log('PASS: signup flag visibility, form mode, error/retry, busy controls, registration payload, automatic sign-in, logout and mobile width');
  console.log('Preview: target/remote-web/signup.png');
} finally {
  await browser?.close();
  server.kill('SIGTERM');
}
