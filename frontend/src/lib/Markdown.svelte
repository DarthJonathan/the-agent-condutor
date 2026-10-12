<script lang="ts">
  import { onMount } from 'svelte';
  import { marked } from 'marked';
  import DOMPurify from 'dompurify';
  let { text, live = false }: { text: string; live?: boolean } = $props();
  let mounted = $state(false); let html = $state('');
  onMount(() => { mounted = true; });
  $effect(() => { if (mounted && !live) html = DOMPurify.sanitize(marked.parse(text, { async: false }), { FORBID_TAGS: ['img', 'svg', 'math', 'style', 'iframe', 'form', 'input', 'button'], FORBID_ATTR: ['style'] }); });
</script>
{#if live || !mounted}<div class="live">{text}</div>{:else}<div class="markdown">{@html html}</div>{/if}
<style>
  .live { white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.65; }
  .markdown { line-height: 1.65; overflow-wrap: anywhere; }
  .markdown :global(pre) { overflow-x: auto; padding: 16px; border-radius: 9px; background: #101214; max-width: 100%; }
  .markdown :global(code) { font: .88em ui-monospace, monospace; }
  .markdown :global(table) { display: block; overflow-x: auto; border-collapse: collapse; max-width: 100%; }
  .markdown :global(th), .markdown :global(td) { border: 1px solid #34383e; padding: 8px 12px; text-align: left; }
  .markdown :global(a) { color: #9db7ff; }
  .markdown :global(blockquote) { margin-left: 0; padding-left: 16px; border-left: 3px solid #6584d9; color: #aeb7c3; }
</style>
