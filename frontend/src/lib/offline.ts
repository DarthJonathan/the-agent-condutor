import type { RunEnvelope } from './protocol';

export type SavedDevice = {
  device: { id: string; name: string; last_seen: string };
  workspaces: { id: string; label: string }[];
  connections: { provider: string; available: boolean; model: string; effort: string }[];
  runs: RunEnvelope[];
};
export type OfflineHistory = {
  schema: 1; user: { id: string; email: string }; savedAt: number;
  selectedDevice: string; selectedRun: string; devices: SavedDevice[];
};
const databaseName = 'conductor-offline';
const maxAge = 7 * 24 * 60 * 60 * 1000;
const maxBytes = 5 * 1024 * 1024;
let writes: Promise<unknown> = Promise.resolve();

function database(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1);
    request.onupgradeneeded = () => request.result.createObjectStore('state');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function transaction<T>(mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await database();
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction('state', mode);
      const request = action(tx.objectStore('state'));
      tx.oncomplete = () => resolve(request.result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } finally { db.close(); }
}
function mutate(action: () => Promise<unknown>): Promise<void> {
  const next = writes.catch(() => {}).then(action);
  writes = next;
  return next.then(() => {});
}
export async function readHistory(): Promise<OfflineHistory | null> {
  const value = await transaction<OfflineHistory | undefined>('readonly', store => store.get('history'));
  if (!value) return null;
  if (value.schema !== 1 || value.savedAt < Date.now() - maxAge) { await clearHistory(); return null; }
  return value;
}
export function clearHistory(): Promise<void> {
  return mutate(() => transaction('readwrite', store => store.delete('history')));
}
export function boundHistory(value: OfflineHistory): OfflineHistory {
  const copy: OfflineHistory = JSON.parse(JSON.stringify(value));
  copy.devices = copy.devices.slice(0, 3);
  for (const device of copy.devices) {
    device.runs.sort((a, b) => (b.run.created_at || '').localeCompare(a.run.created_at || ''));
    // Keep the selected reply even when older than the other visited conversations.
    device.runs.sort((a, b) => Number(b.run_id === copy.selectedRun) - Number(a.run_id === copy.selectedRun));
    device.runs = device.runs.slice(0, 20);
  }
  while (new TextEncoder().encode(JSON.stringify(copy)).byteLength > maxBytes) {
    const device = [...copy.devices].reverse().find(item => item.runs.length);
    if (!device) throw new Error('Offline metadata exceeds storage limit');
    device.runs.pop();
  }
  return copy;
}
export function writeHistory(value: OfflineHistory): Promise<void> {
  const bounded = boundHistory(value);
  return mutate(() => transaction('readwrite', store => store.put(bounded, 'history')));
}
