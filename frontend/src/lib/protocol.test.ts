import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyPatches, mergeEvent } from './protocol.ts';

test('streaming append preserves unicode and older reply identity', () => {
  const before = { messages: [{ text: 'A completed reply' }, { text: 'Hello' }] };
  const after = applyPatches(before, [{ op: 'append', path: ['messages','1','text'], value: ' 🦀' }]);
  assert.equal(after.messages[1].text, 'Hello 🦀'); assert.equal(before.messages[1].text, 'Hello'); assert.equal(after.messages[0].text, before.messages[0].text);
});
test('duplicate events are ignored and missing versions trigger recovery', () => {
  const current = { run_id: 'run', workspace_id: 'project', generation: 'boot', version: 4, run: { text: 'hello' } };
  assert.equal(mergeEvent(current, { kind:'run_patch', generation:'boot', version:4 }), current);
  assert.throws(() => mergeEvent(current, { kind:'run_patch', generation:'boot', version:6, base_version:5, changes:[] }));
  assert.equal(mergeEvent(current, { kind:'run_deleted' }), undefined);
});
test('prototype and invalid array patches are rejected', () => {
  assert.throws(() => applyPatches({}, [{ op:'set', path:['__proto__','polluted'], value:true }]));
  assert.throws(() => applyPatches({items:[]}, [{op:'set',path:['items','500'],value:'bad'}]));
  assert.throws(() => applyPatches({}, [{op:'append',path:['missing'],value:'bad'}]));
  assert.equal(({} as any).polluted, undefined);
});
test('inactive conversation events update summaries without loading the transcript', () => {
  const event = {kind:'run_summary',run_id:'run',workspace_id:'project',generation:'boot',version:1,summary:true,run:{id:'run',title:'Task',status:'Completed'}};
  const next = mergeEvent(undefined,event)!;
  assert.equal(next.summary,true);assert.equal(next.run.title,'Task');assert.equal(next.run.conversation,undefined);
});
