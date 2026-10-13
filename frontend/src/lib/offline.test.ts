import assert from 'node:assert/strict';
import test from 'node:test';
import { boundHistory, type OfflineHistory } from './offline.ts';

const fixture = (): OfflineHistory => ({
  schema: 1, user: { id: 'fixture', email: 'fixture@example.test' }, savedAt: 1,
  selectedDevice: 'device-0', selectedRun: 'run-0',
  devices: Array.from({ length: 4 }, (_, d) => ({
    device: { id: `device-${d}`, name: 'Fixture Mac', last_seen: '' }, workspaces: [], connections: [],
    runs: Array.from({ length: 30 }, (_, i) => ({ run_id: `run-${i}`, workspace_id: 'workspace', generation: 'generation', version: 1,
      run: { created_at: String(i).padStart(2, '0'), text: 'reply' } }))
  }))
});
test('offline retention bounds devices and chats while preserving the selected older conversation', () => {
  const original = fixture(); const bounded = boundHistory(original);
  assert.equal(bounded.devices.length, 3);
  assert(bounded.devices.every(d => d.runs.length === 20));
  assert.equal(bounded.devices[0].runs[0].run_id, 'run-0');
  assert.equal(original.devices.length, 4);
  assert.equal(original.devices[0].runs.length, 30);
});
test('UTF-8 offline copies stay within the byte limit', () => {
  const value = fixture();
  for (const device of value.devices) for (const run of device.runs) run.run.text = '🦀'.repeat(100_000);
  const bounded = boundHistory(value);
  assert(new TextEncoder().encode(JSON.stringify(bounded)).byteLength <= 5 * 1024 * 1024);
  assert.equal(bounded.devices[0].runs[0].run_id, 'run-0');
});
