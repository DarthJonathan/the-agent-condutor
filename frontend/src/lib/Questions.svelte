<script lang="ts">
  let { request, send, disabled = false }: { request: any; send: (answers: any[]) => Promise<void>; disabled?: boolean } = $props();
  let answers = $state<Record<string, string[]>>({}); let custom = $state<Record<string, string>>({}); let skipped = $state<Record<string, boolean>>({}); let pending = $state(false);
  function choose(question: any, id: string, checked: boolean) {
    const current = answers[question.id] || [];
    answers[question.id] = question.multi_select ? checked ? [...current.filter(v => v !== id), id] : current.filter(v => v !== id) : [id];
  }
  async function submit() { pending = true; try { await send(request.questions.map((q: any) => ({ question_id: q.id, option_ids: skipped[q.id] ? [] : answers[q.id] || [], text: skipped[q.id] ? '' : custom[q.id] || '', skipped: skipped[q.id] || false }))); } catch {} finally { pending = false; } }
</script>
<form onsubmit={(e) => { e.preventDefault(); void submit(); }}>
  {#each request.questions as question}
    <fieldset disabled={pending || disabled}><legend>{question.question}</legend>
      {#each question.options || [] as option}<label><input type={question.multi_select ? 'checkbox' : 'radio'} name={question.id} value={option.id} checked={(answers[question.id] || []).includes(option.id)} disabled={skipped[question.id]} onchange={e => choose(question, option.id, e.currentTarget.checked)}/><span>{option.label}<small>{option.description || ''}</small></span></label>{/each}
      <textarea bind:value={custom[question.id]} placeholder="Your answer or additional details…" aria-label="Custom answer"></textarea>
      <label class="skip"><input type="checkbox" bind:checked={skipped[question.id]}/>Skip this question</label>
    </fieldset>
  {/each}
  <button disabled={pending || disabled || request.questions.some((q: any) => !skipped[q.id] && !answers[q.id]?.length && !custom[q.id]?.trim())}>{pending ? 'Sending…' : 'Send answers'}</button>
</form>
<style>
  fieldset { border: 0; margin: 18px 0; padding: 0; } legend { font-weight: 600; margin-bottom: 12px; }
  label { display: flex; align-items: start; gap: 10px; margin: 8px 0; padding: 12px; background: #141619; border-radius: 8px; }
  small { display: block; opacity: .65; } textarea { box-sizing: border-box; width: 100%; min-height: 70px; padding: 12px; color: inherit; background: #141619; border: 1px solid #34383e; border-radius: 8px; font: inherit; }.skip { background: transparent; }
  button { background: #7794e8; color: #101214; padding: 10px 16px; border: 0; border-radius: 8px; cursor: pointer; } button:disabled { opacity: .45; }
</style>
