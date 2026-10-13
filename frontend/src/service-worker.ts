/// <reference lib="webworker" />
import { build, files, version } from '$service-worker';

const worker = self as unknown as ServiceWorkerGlobalScope;
const prefix = 'conductor-shell-';
const cacheName = `${prefix}${version}`;
// The root is an anonymous shell: account data is loaded only through the API.
const assets = [...new Set([...build, ...files, '/'])];
const assetPaths = new Set(assets);

worker.addEventListener('install', event => {
  // Preserve the shell's CSP headers and fetch it without account cookies.
  event.waitUntil(caches.open(cacheName).then(cache => cache.addAll(assets.map(url => new Request(url, { credentials: 'omit' })))));
});

worker.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith(prefix) && name !== cacheName) await caches.delete(name);
    }
    await worker.clients.claim();
  })());
});

worker.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);
  // Authentication, SSE, API responses and commands always go to the network.
  if (request.method !== 'GET' || url.origin !== worker.location.origin || url.pathname.startsWith('/api/')) return;
  if (request.mode === 'navigate' && url.pathname === '/') {
    event.respondWith((async () => {
      try {
        const response = await fetch(request, { signal: AbortSignal.timeout(5000) });
        if (response.ok) return response;
      } catch { /* Use the public shell when the network/server is unavailable. */ }
      return (await caches.open(cacheName)).match('/').then(response => response || Response.error());
    })());
  } else if (assetPaths.has(url.pathname)) {
    event.respondWith((async () => (await (await caches.open(cacheName)).match(url.pathname)) || fetch(request))());
  }
});
