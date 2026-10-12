<script lang="ts">
  import { onMount } from 'svelte';
  import Markdown from '$lib/Markdown.svelte';
  import Questions from '$lib/Questions.svelte';
  import { mergeEvent, type RunEnvelope } from '$lib/protocol';
  let user = $state<any>(null); let csrf = ''; let email = $state(''); let password = $state(''); let signup = $state(false); let allowSignup = $state(false);
  let busy = $state(false); let error = $state(''); let notice = $state(''); let devices = $state<any[]>([]); let deviceID = $state('');
  let device = $state<any>(null); let spaces = $state<any[]>([]); let workspaceID = $state(''); let connections = $state<any[]>([]);
  let runs = $state<Record<string, RunEnvelope>>({}); let runID = $state(''); let prompt = $state(''); let targetID = $state(''); let commands = $state<any[]>([]);
  let stream: EventSource | null = null; let streamReady = $state(false); let visibleCount = $state(40); let team = $state<string[]>([]); let draftModel = $state(''); let draftEffort = $state('default');
  let retryCommand: any = null; let mentionIndex = $state(0);
  let pendingChat: { workspace: string; prompt: string; known: Set<string> } | null = null;
  const providerName = (provider: string) => ({ claude: 'Claude', codex: 'Codex', antigravity: 'Antigravity', qoder: 'Qoder', deep_seek: 'DeepSeek', deepseek: 'DeepSeek', kiro: 'Kiro' }[provider] || provider);
  const active = $derived(runs[runID]?.run); const online = $derived(device && Date.now() - new Date(device.last_seen).getTime() < 45000 && streamReady);
  const chatRuns = $derived(Object.values(runs).filter(r => r.workspace_id === workspaceID).sort((a,b) => (b.run.created_at || '').localeCompare(a.run.created_at || '')));
  const coworkers = $derived(active?.conversation?.coworkers || []); const messages = $derived(active?.conversation?.messages || []);
  const mentionQuery = $derived(prompt.match(/(?:^|\s)@([\w-]*)$/)?.[1]);
  const mentions = $derived(mentionQuery === undefined ? [] : coworkers.filter((w: any) => w.mention.startsWith(mentionQuery.toLowerCase()) || w.name.toLowerCase().startsWith(mentionQuery.toLowerCase())));
  async function api(path: string, method = 'GET', body?: any): Promise<any> {
    const response = await fetch(`/api/v1${path}`, { method, credentials: 'same-origin', headers: { 'content-type': 'application/json', ...(method === 'GET' ? {} : { 'x-csrf-token': csrf }) }, body: body === undefined ? undefined : JSON.stringify(body) });
    const data = await response.json(); if (!response.ok) { if (response.status === 401 && !path.includes('/auth/login')) { user = null; stream?.close(); } throw new Error(data.error || `Request failed (${response.status})`); } return data;
  }
  async function login() { busy = true; error = ''; try { const data = await api(`/auth/${signup ? 'register' : 'login'}`, 'POST', { email, password }); user = data.user; csrf = data.csrf; password = ''; await loadDevices(); } catch(e) { error = String((e as Error).message); } finally { busy = false; } }
  async function logout() { try { await api('/auth/logout', 'POST', {}); } finally { stream?.close(); user = null; deviceID = ''; runs = {}; csrf = ''; } }
  async function loadDevices() { devices = (await api('/devices')).devices; if (!deviceID && devices.length) chooseDevice(devices[0].id); }
  function metadata(data: any) {
    device = data.device; spaces = data.workspaces || []; connections = data.connections || []; commands = data.commands || [];
    const allowed = new Set(spaces.map(w => w.id)); runs = Object.fromEntries(Object.entries(runs).filter(([,r]) => allowed.has(r.workspace_id)));
    if (!allowed.has(workspaceID)) workspaceID = spaces[0]?.id || '';
    if (!team.length) team = connections.filter(c => c.available).slice(0, 1).map(c => c.provider);
  }
  function openedChat(next: RunEnvelope) { if (pendingChat && next.workspace_id === pendingChat.workspace && !pendingChat.known.has(next.run_id) && next.run.prompt?.startsWith(pendingChat.prompt.slice(0,32))) { pendingChat = null; selectRun(next.run_id); } }
  function snapshot(data: any) { metadata(data); runs = Object.fromEntries((data.runs || []).map((r: RunEnvelope) => [r.run_id, r])); if (runID && !runs[runID]) runID = ''; for (const run of Object.values(runs)) openedChat(run); }
  async function recover() { if (!deviceID) return; try { snapshot(await api(`/devices/${deviceID}${runID ? `?run_id=${encodeURIComponent(runID)}` : ''}`)); } catch(e) { error = (e as Error).message; } }
  function chooseDevice(id: string) {
    stream?.close(); deviceID = id; runs = {}; runID = ''; workspaceID = ''; team = []; streamReady = false; error = ''; pendingChat = null;
    openStream(id);
  }
  function openStream(id: string, selected = '') {
    stream?.close(); streamReady = false;
    const source = new EventSource(`/api/v1/events?device_id=${encodeURIComponent(id)}${selected ? `&run_id=${encodeURIComponent(selected)}` : ''}`); stream = source;
    source.addEventListener('snapshot', e => { if (stream !== source) return; streamReady = true; snapshot(JSON.parse((e as MessageEvent).data)); });
    for (const kind of ['run_snapshot', 'run_patch', 'run_deleted','run_summary']) source.addEventListener(kind, e => {
      if (stream !== source) return;
      try { const event = JSON.parse((e as MessageEvent).data); const next = mergeEvent(runs[event.run_id], event); if (next) { runs[event.run_id] = next; openedChat(next); } else { delete runs[event.run_id]; if (runID === event.run_id) runID = ''; } }
      catch { void recover(); }
    });
    source.addEventListener('presence', e => { if (stream !== source) return; metadata(JSON.parse((e as MessageEvent).data)); streamReady = true; });
    source.onopen = () => { if (stream === source) streamReady = true; };
    source.onerror = () => { if (stream !== source) return; streamReady = false; void api('/auth/session').catch(() => {}); };
  }
  function selectRun(id: string) { runID = id; visibleCount = 40; targetID = ''; notice = ''; openStream(deviceID,id); }
  function newChat() { runID = ''; targetID = ''; prompt = ''; notice = ''; retryCommand = null; pendingChat = null; if (deviceID) openStream(deviceID); }
  async function send(kind: string, payload: any) {
    error = ''; if (!online) { error = 'Your Mac is offline. Reconnect it before sending a command.'; throw new Error(error); }
    const signature = JSON.stringify({ deviceID, workspaceID, kind, payload });
    const command = retryCommand?.signature === signature ? retryCommand.command : { id: crypto.randomUUID(), workspace_id: workspaceID, kind, payload };
    retryCommand = { signature, command };
    if (kind === 'chat' && !pendingChat) pendingChat = { workspace: workspaceID, prompt: payload.prompt, known: new Set(Object.keys(runs)) };
    try { const result = await api(`/devices/${deviceID}/commands`, 'POST', command); commands = [result, ...commands.filter(c => c.id !== result.id)].slice(0,20); retryCommand = null; notice = 'Queued for your Mac.'; }
    catch(e) { error = (e as Error).message; throw e; }
  }
  async function submit() { if (!prompt.trim() || busy) return; busy = true; try {
    if (active) await send('message', { run_id: runID, prompt, target_id: targetID || null });
    else await send('chat', { prompt, providers: team, model: team.length === 1 ? draftModel : '', effort: draftEffort });
    if (!error) prompt = '';
  } catch {} finally { busy = false; } }
  function insertMention(worker: any) { prompt = prompt.replace(/@([\w-]*)$/, `@${worker.mention} `); mentionIndex = 0; }
  function keydown(e: KeyboardEvent) { if (mentions.length && ['ArrowDown','ArrowUp','Tab','Enter','Escape'].includes(e.key) && !e.metaKey && !e.ctrlKey) {
    e.preventDefault(); if (e.key === 'ArrowDown') mentionIndex = (mentionIndex + 1) % mentions.length; else if (e.key === 'ArrowUp') mentionIndex = (mentionIndex + mentions.length - 1) % mentions.length; else if (e.key === 'Escape') prompt += ' '; else insertMention(mentions[mentionIndex % mentions.length]);
  } else if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); void submit(); } }
  async function revoke() { if (!confirm(`Disconnect ${device?.name}? This removes its remote chat copies and stops remote commands. The original chats stay on your Mac.`)) return; try { await api(`/devices/${deviceID}`, 'DELETE'); stream?.close(); deviceID = ''; device = null; runs = {}; await loadDevices(); } catch(e) { error = (e as Error).message; } }
  onMount(() => { void api('/auth/options').then(data => allowSignup = data.signup_enabled).catch(() => {}); void api('/auth/session').then(data => { user = data.user; csrf = data.csrf; return loadDevices(); }).catch(() => {}); return () => stream?.close(); });
</script>

<svelte:head><title>Conductor · Remote workspace</title><meta name="description" content="Your agent coworkers, wherever you are."/><link rel="icon" type="image/png" href="/icon.png"/></svelte:head>
{#if !user}
  <main class="login"><div class="login-card"><img class="app-icon" src="/icon.png" alt="Conductor"/><h1>Your workspace,<br/>wherever you are.</h1><p>Connect to Conductor on your Mac and pick up the conversation.</p>
    <form onsubmit={e => { e.preventDefault(); void login(); }}><label>Email<input type="email" bind:value={email} autocomplete="username" required/></label><label>Password<input type="password" bind:value={password} autocomplete={signup ? 'new-password' : 'current-password'} minlength={signup ? 12 : undefined} required/></label>
      {#if error}<div class="error" role="alert">{error}</div>{/if}<button class="primary" disabled={busy}>{busy ? 'Signing in…' : signup ? 'Create account' : 'Sign in'}</button>
    </form>{#if allowSignup}<button class="quiet" onclick={() => { signup = !signup; error = ''; }}>{signup ? 'Back to sign in' : 'Create a development account'}</button>{/if}<small>{allowSignup ? 'Create an account, then pair your Mac from its Remote screen.' : 'Use an account provisioned by the server owner.'}</small>
  </div></main>
{:else}
  <div class="app">
    <aside><a class="brand" href="/"><img src="/icon.png" alt="" width="28" height="28"/><strong>Conductor</strong><span>REMOTE</span></a><button class="new" onclick={newChat}>＋ New conversation</button>
      <label class="caption">Computer<select aria-label="Computer" value={deviceID} onchange={e => chooseDevice(e.currentTarget.value)}>{#each devices as d}<option value={d.id}>{d.name}</option>{/each}</select></label>
      <label class="caption">Workspace<select aria-label="Workspace" bind:value={workspaceID} onchange={newChat}>{#each spaces as w}<option value={w.id}>{w.label}</option>{/each}</select></label>
      <div class="caption">Conversations</div><nav>{#each chatRuns as r}<button class:chosen={r.run_id === runID} onclick={() => selectRun(r.run_id)}><span class="dot" class:working={r.run.status === 'Running'}></span><span>{r.run.title || r.run.prompt?.slice(0,60) || 'Conversation'}</span></button>{/each}</nav>
      <footer><span>{user.email}</span><button class="quiet" onclick={() => void logout()}>Sign out</button></footer>
    </aside>
    <main class="workspace"><header><div><h1>{active?.title || 'New conversation'}</h1><div class="muted"><span class="dot" class:connected={online}></span>{device?.name || 'No paired computer'} · {online ? 'Connected' : 'Offline'}</div></div>
      {#if active?.status === 'Running'}<button class="danger" onclick={() => void send('cancel',{run_id:runID}).catch(() => {})}>Stop agents</button>{/if}
    </header>
    {#if error}<div class="error" role="alert">{error}</div>{/if}
    {#if !devices.length}<div class="empty"><h2>Pair your Mac</h2><p>Open Conductor → Remote, sign in to this server, and choose the folders to share.</p><button onclick={() => void loadDevices()}>Check for paired computers</button></div>
    {:else if !workspaceID}<div class="empty"><h2>No folders shared yet</h2><p>Choose folders in the Mac app’s Remote screen.</p></div>
    {:else}
      <section class="transcript" aria-label="Conversation">
        {#if !active}<div class="empty"><div class="brand-mark">↗</div><h2>Start something from here.</h2><p>Your coworkers run on {device?.name}. Their replies appear here as they work.</p></div>{/if}
        {#if messages.length > visibleCount}<button class="quiet older" onclick={() => visibleCount += 40}>Load older messages</button>{/if}
        {#if active?.remote_omitted_messages}<p class="muted">{active.remote_omitted_messages} older messages are available in the Mac app. This web view keeps a recent copy.</p>{/if}
        {#each messages.slice(-visibleCount) as message (message.id)}
          <article class:user-message={message.kind === 'user'}><div class="message-heading"><strong>{message.kind === 'user' ? 'You' : coworkers.find((w: any) => w.id === message.author_id)?.name || message.author || 'Conductor'}</strong><span>{message.model || ''}{message.status === 'Running' ? ' · Working…' : ''}</span></div>
            <Markdown text={message.text || ''} live={message.status === 'Running'}/>
            {#if message.error}<div class="error">{message.error}</div>{/if}
            {#if message.remote_truncated}<small>This reply is shortened for remote access. The full reply is available on your Mac.</small>{/if}
            {#if message.question_request && !message.question_request.answers}<div class="question"><strong>Needs your answer</strong><Questions request={message.question_request} send={answers => send('answer',{run_id:runID,message_id:message.id,request_id:message.question_request.id,answers})}/></div>{/if}
            {#if message.approval_request && message.approval_request.decision == null}<div class="question"><strong>Approval requested</strong><p>{message.approval_request.summary}</p><pre>{JSON.stringify(message.approval_request.argv)}</pre><button class="primary" onclick={() => { if(confirm('Approve this operation on your Mac?')) void send('approval',{run_id:runID,message_id:message.id,request_id:message.approval_request.id,approved:true}).catch(() => {}); }}>Approve</button><button onclick={() => void send('approval',{run_id:runID,message_id:message.id,request_id:message.approval_request.id,approved:false}).catch(() => {})}>Decline</button></div>{/if}
          </article>
        {/each}
        {#if active && !messages.length}{#each active.stages || [] as stage}<article><strong>{stage.provider}</strong><Markdown text={stage.output || ''} live={stage.status === 'Running'}/></article>{/each}{/if}
      </section>
      <form class="composer" onsubmit={e => { e.preventDefault(); void submit(); }}>
        {#if mentions.length}<div class="mention-list" role="listbox" aria-label="Mention a coworker">{#each mentions as worker,index}<button type="button" role="option" aria-selected={index === mentionIndex % mentions.length} class:chosen={index === mentionIndex % mentions.length} onclick={() => insertMention(worker)}>{worker.name}<span>@{worker.mention}</span></button>{/each}</div>{/if}
        <textarea bind:value={prompt} onkeydown={keydown} placeholder={online ? 'Message a coworker, or @mention a teammate…' : 'Your Mac is offline. You can still read saved conversations.'} aria-label="Message" disabled={!online}></textarea>
        <div class="composer-bottom"><div>{#if active}<select aria-label="Talk to" bind:value={targetID}><option value="">Lead coworker</option>{#each coworkers as w}<option value={w.id}>{w.name}</option>{/each}</select>{:else}<span class="muted">Choose coworkers in the team panel</span>{/if}</div><button class="primary" disabled={!online || busy || !prompt.trim() || (!active && !team.length)}>{busy ? 'Sending…' : 'Send ↗'}</button></div>
        {#if notice}<small>{notice}</small>{/if}{#if commands[0]}<small>Last command: {commands[0].status}{commands[0].result ? ` · ${commands[0].result}` : ''}</small>{/if}
      </form>
    {/if}</main>
    <section class="inspector"><h2>{active ? 'Your coworkers' : 'Build your team'}</h2>
      {#if active}{#each coworkers as worker}<div class="coworker"><strong>{worker.name}</strong><span>@{worker.mention} · {worker.provider}</span><span>{worker.attention?.replaceAll('_',' ') || 'idle'}</span><input aria-label={`${worker.name} model`} placeholder="Connection default model" value={worker.model || ''} onchange={e => void send('coworker',{run_id:runID,coworker_id:worker.id,model:e.currentTarget.value,effort:worker.effort || 'default'}).catch(() => {})}/><select aria-label={`${worker.name} effort`} value={worker.effort || 'default'} onchange={e => void send('coworker',{run_id:runID,coworker_id:worker.id,model:worker.model || '',effort:e.currentTarget.value}).catch(() => {})}>{#each ['default','none','minimal','low','medium','high','xhigh','max','ultra'] as effort}<option>{effort}</option>{/each}</select></div>{/each}
      {:else}{#each connections as connection}<label class="connection"><input type="checkbox" value={connection.provider} bind:group={team} disabled={!connection.available}/><strong>{providerName(connection.provider)}</strong><span>{connection.available ? 'Ready' : 'Unavailable'}</span></label>{/each}<label>Model<input bind:value={draftModel} placeholder="Use connection defaults" disabled={team.length !== 1}/></label>{#if team.length > 1}<small>Each coworker starts with its connection's model. Change individual models after opening the conversation.</small>{/if}<label>Effort<select bind:value={draftEffort}>{#each ['default','none','minimal','low','medium','high','xhigh','max','ultra'] as effort}<option>{effort}</option>{/each}</select></label>{/if}
      {#if active?.changes?.files?.length}<details><summary>Changes</summary>{#each active.changes.files as file}<div><strong>{file.path}</strong><pre>{file.diff || ''}</pre></div>{/each}</details>{/if}
      {#if active?.changes?.checks?.length}<details><summary>Checks</summary>{#each active.changes.checks as check}<div><strong>{check.status || 'Check result'}</strong><pre>{check.output || ''}</pre></div>{/each}</details>{/if}
      {#if active?.conversation?.mailbox?.length}<details><summary>Mailbox</summary>{#each active.conversation.mailbox as mail}<p>{mail.state}: {mail.text?.slice(0,250)}</p>{/each}</details>{/if}
      <p class="muted">Only folders shared in the Mac app are accessible here.</p><button class="quiet" onclick={() => void revoke()} disabled={!deviceID}>Disconnect this computer</button>
    </section>
  </div>
{/if}

<style>
  .app-icon { width: 56px; height: 56px; border-radius: 14px; }
  :global(*) { box-sizing: border-box; } :global(body) { margin: 0; color: #e9edf3; background: #111315; font: 14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; } :global(button), :global(input), :global(select), :global(textarea) { font: inherit; }
  :global(button) { cursor: pointer; color: inherit; background: #25292e; border: 1px solid #34383e; border-radius: 8px; padding: 9px 13px; } :global(button:disabled) { cursor: default; opacity: .45; } :global(input:not([type=checkbox]):not([type=radio])), :global(select) { width: 100%; padding: 10px; color: inherit; background: #171a1e; border: 1px solid #34383e; border-radius: 8px; } :global(label) { display: block; margin: 15px 0; } :global(label input), :global(label select) { margin-top: 7px; }
  :global(.primary) { background: #839df0; color: #111827; border-color: #839df0; font-weight: 600; } :global(.quiet) { background: transparent; border-color: transparent; color: #9cafd8; } :global(.error) { padding: 12px; margin: 12px 0; border-radius: 8px; color: #ffb0a8; background: #352124; } :global(.muted) { color: #8d98a7; font-size: 12px; } :global(small) { display: block; color: #8d98a7; margin-top: 10px; font-size: 11px; }
  .login { display: grid; min-height: 100dvh; place-items: center; padding: 24px; background: radial-gradient(ellipse at top,#1c273f,transparent 60%); }.login-card { width: min(390px,100%); }.login h1 { font-size: 38px; line-height: 1.15; letter-spacing: -1.2px; }.login p { color: #9ca8b8; line-height: 1.7; }.login .primary { width: 100%; margin-top: 12px; }.brand-mark { display: grid; place-items: center; width: 46px; height: 46px; border-radius: 13px; background: #293c68; color: #abc4ff; font-weight: 700; font-size: 25px; }
  .app { display: grid; grid-template-columns: 245px minmax(0,1fr) 255px; height: 100dvh; }.app aside { display: flex; flex-direction: column; padding: 24px 16px 16px; border-right: 1px solid #282c31; background: #151719; min-height: 0; }.brand { display: flex; gap: 9px; align-items: center; color: inherit; text-decoration: none; font-size: 19px; margin-bottom: 30px; }.brand span { font-size: 9px; letter-spacing: 1px; padding: 4px 6px; color: #a2bfff; background: #21304e; border-radius: 4px; }.new { text-align: left; }.caption { font-size: 11px; color: #94a0af; margin-top: 24px; text-transform: uppercase; letter-spacing: .7px; } nav { overflow-y: auto; flex: 1; margin-top: 10px; } nav button { display: flex; align-items: center; gap: 8px; text-align: left; width: 100%; margin: 3px 0; background: transparent; border-color: transparent; } nav button span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.chosen { background: #27314a!important; } footer { display: flex; justify-content: space-between; align-items: center; gap: 4px; font-size: 11px; color: #94a0af; border-top: 1px solid #282c31; padding-top: 15px; } footer span { overflow: hidden; text-overflow: ellipsis; }
  .workspace { display: flex; flex-direction: column; min-width: 0; min-height: 0; padding: 28px 32px 20px; } header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 22px; border-bottom: 1px solid #282c31; gap: 12px; } header h1 { font-size: 20px; margin: 0 0 8px; letter-spacing: -.4px; } .dot { display: inline-block; width: 6px; height: 6px; background: #677180; border-radius: 50%; flex-shrink: 0; margin-right: 4px; }.dot.connected { background: #74c6a9; }.dot.working { background: #9db5ff; }.danger { color: #ffaaa2; background: #302022; border-color: #543035; }
  .transcript { flex: 1; overflow-y: auto; overflow-x: hidden; min-height: 0; padding: 22px 0; scrollbar-gutter: stable; }.empty { margin: auto; padding: 40px 20px; text-align: center; color: #9ba7b7; }.empty .brand-mark { margin: 28px auto; }.empty h2 { color: #e9edf3; font-size: 23px; }.empty p { max-width: 420px; margin: 12px auto; line-height: 1.7; } article { margin-bottom: 16px; padding: 22px; background: #1b1e22; border: 1px solid #2c3138; border-radius: 12px; content-visibility: auto; contain-intrinsic-size: auto 220px; } .user-message { background: #1c2330; }.message-heading { display: flex; justify-content: space-between; gap: 12px; margin-bottom: 14px; }.message-heading span { color: #8995a5; font-size: 11px; }.question { border: 1px solid #886035; padding: 16px; margin-top: 20px; border-radius: 10px; }.older { width: 100%; margin-bottom: 20px; } pre { overflow: auto; font-size: 12px; }
  .composer { position: relative; border: 1px solid #363d49; border-radius: 13px; background: #1b1f25; padding: 16px; margin-top: 8px; }.composer textarea { width: 100%; min-height: 75px; max-height: 180px; resize: vertical; border: 0; outline: none; background: transparent; color: inherit; line-height: 1.6; }.composer-bottom { display: flex; justify-content: space-between; align-items: center; margin-top: 12px; gap: 12px; }.composer-bottom select { width: auto; }.mention-list { position: absolute; bottom: calc(100% + 8px); left: 0; width: min(360px,100%); background: #222833; padding: 8px; border: 1px solid #45506a; border-radius: 11px; box-shadow: 0 12px 35px #0008; z-index: 3; }.mention-list button { display: flex; justify-content: space-between; width: 100%; background: transparent; border: 0; }.mention-list span { color: #a4bcff; }
  .inspector { border-left: 1px solid #282c31; padding: 30px 18px; overflow-y: auto; }.inspector h2 { font-size: 14px; margin-bottom: 25px; }.connection { display: flex; gap: 10px; align-items: center; background: #1b1e22; border-radius: 8px; padding: 12px; }.connection input { margin: 0; }.connection span { color: #8d98a7; font-size: 10px; margin-left: auto; }.coworker { display: flex; flex-direction: column; gap: 8px; background: #1b1e22; padding: 15px; border-radius: 9px; margin: 10px 0; }.coworker span { color: #94a0af; font-size: 11px; } details { margin: 22px 0; } summary { cursor: pointer; color: #afc5ff; } .inspector .muted { margin-top: 30px; line-height: 1.7; }
  footer span { min-width: 0; overflow-wrap: anywhere; } footer button { white-space: nowrap; flex-shrink: 0; }
  @media(max-width:1100px) { .app { grid-template-columns: 210px minmax(0,1fr); height: auto; min-height: 100dvh; } aside { grid-row: 1/3; }.workspace { height: 100dvh; padding: 20px; }.inspector { grid-column: 2; border-top: 1px solid #282c31; } }
  @media(max-width:650px) { .app { display: flex; flex-direction: column; }.app aside { padding: 14px; border-bottom: 1px solid #282c31; }.brand { margin-bottom: 14px; } nav { max-height: 130px; }.caption { margin-top: 12px; } aside footer { margin-top: 14px; }.workspace { height: 80dvh; min-height: 600px; padding: 18px 12px; }.inspector { border-left: 0; } article { padding: 16px; } }
</style>
