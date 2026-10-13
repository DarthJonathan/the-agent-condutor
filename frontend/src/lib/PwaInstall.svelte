<script lang="ts">
  import { onMount } from 'svelte';
  type InstallPrompt = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };
  let prompt = $state<InstallPrompt | null>(null);
  let installed = $state(false);
  let instructions = $state(false);
  onMount(() => {
    installed = matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
    const ready = (event: Event) => { event.preventDefault(); prompt = event as InstallPrompt; };
    const complete = () => { installed = true; prompt = null; };
    window.addEventListener('beforeinstallprompt', ready);
    window.addEventListener('appinstalled', complete);
    return () => { window.removeEventListener('beforeinstallprompt', ready); window.removeEventListener('appinstalled', complete); };
  });
  async function install() {
    if (!prompt) { instructions = !instructions; return; }
    const available = prompt; prompt = null;
    await available.prompt();
    if ((await available.userChoice).outcome !== 'accepted') instructions = true;
  }
</script>
{#if !installed}
  <div class="install"><button type="button" class="quiet" onclick={() => void install()}>Install app</button>
    {#if instructions}<p>On iPhone or iPad, open this site in Safari, then use Share → Add to Home Screen. On desktop or Android, use your browser’s Install app option.</p>{/if}
  </div>
{/if}
<style>
  .install { margin-top: 10px; } button { width: 100%; text-align: left; } p { margin: 8px 0; color: #9ca8b8; font-size: 12px; line-height: 1.6; }
</style>
