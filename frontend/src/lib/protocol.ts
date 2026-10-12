export type Patch = { op: 'set' | 'append' | 'remove'; path: string[]; value?: unknown };
export type RunEnvelope = { run_id: string; workspace_id: string; generation: string; version: number; summary?: boolean; run: Record<string, any> };
export function applyPatches(root: Record<string, any>, changes: Patch[]): Record<string, any> {
  const copy = structuredClone(root);
  for (const change of changes) {
    if (!change.path.length || change.path.length > 32 || change.path.some(x => ['__proto__', 'constructor', 'prototype'].includes(x))) throw new Error('Invalid patch');
    let parent: any = copy;
    for (const key of change.path.slice(0, -1)) { parent = parent[key]; if (parent == null || typeof parent !== 'object') throw new Error('Missing patch parent'); }
    const key = change.path.at(-1)!;
    if (Array.isArray(parent) && (!/^\d+$/.test(key) || Number(key) > parent.length)) throw new Error('Invalid array index');
    if (change.op === 'set') parent[key] = change.value;
    else if (change.op === 'append' && typeof parent[key] === 'string' && typeof change.value === 'string') parent[key] += change.value;
    else if (change.op === 'remove') { if (Array.isArray(parent)) parent.splice(Number(key), 1); else delete parent[key]; }
    else throw new Error('Invalid patch operation');
  }
  return copy;
}
export function mergeEvent(current: RunEnvelope | undefined, event: any): RunEnvelope | undefined {
  if (event.kind === 'run_deleted') return undefined;
  if (current && current.generation === event.generation && current.version >= event.version) return current;
  if (event.kind === 'run_summary') return { ...event, summary: true };
  if (event.kind === 'run_snapshot') return { ...event, run: event.run };
  if (!current || current.generation !== event.generation || current.version !== event.base_version) throw new Error('Snapshot recovery required');
  return { ...current, version: event.version, run: applyPatches(current.run, event.changes) };
}
