/* ════════════════════════════════════════════════════════════════════════
 * KataClimb Service Worker
 * v3.56b — Step 2/5 PWA scheletro
 *
 * STRATEGIA
 *   - HTML (portale/agenda/index): network-first, cache fallback
 *   - Asset statici (icone, manifest): cache-first
 *   - Supabase/Workers/Stream: NESSUNA cache (passthrough)
 *
 * VERSIONING
 *   CACHE_VERSION bump → invalida cache vecchia automaticamente
 *
 * HOOK PRONTI (attivati in Step 4-5)
 *   - 'push' event: mostra notifica nativa
 *   - 'notificationclick': apre PWA / focus tab esistente
 * ════════════════════════════════════════════════════════════════════════ */

const CACHE_VERSION = 'kc-v3.56b';
const CACHE_STATIC  = `${CACHE_VERSION}-static`;

// Asset pre-cache all'install (solo icone + manifest, NIENTE HTML)
const PRECACHE_URLS = [
  '/site.webmanifest',
  '/favicon-192x192.png',
  '/favicon-512x512.png',
  '/apple-touch-icon.png',
  '/favicon.ico',
];

// Domini esterni da NON intercettare mai (passthrough totale)
const PASSTHROUGH_HOSTS = [
  'supabase.co',
  'supabase.io',
  'workers.dev',
  'cloudflarestream.com',
  'videodelivery.net',
  'brevo.com',
  'stripe.com',
];

/* ─── INSTALL ─────────────────────────────────────────────────────── */
self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_STATIC);
    try {
      await cache.addAll(PRECACHE_URLS);
    } catch (e) {
      // Se uno degli asset manca, non bloccare l'install
      console.warn('[sw] precache parziale:', e);
    }
    // Attiva immediatamente la nuova versione invece di attendere reload
    await self.skipWaiting();
  })());
});

/* ─── ACTIVATE ────────────────────────────────────────────────────── */
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Pulisce cache vecchie (mantiene solo quelle del CACHE_VERSION attuale)
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((k) => !k.startsWith(CACHE_VERSION))
        .map((k) => caches.delete(k))
    );
    // Prende controllo immediato dei client esistenti
    await self.clients.claim();
  })());
});

/* ─── FETCH (strategia per tipo) ──────────────────────────────────── */
self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Solo GET cachable
  if (req.method !== 'GET') return;

  // Passthrough totale per domini esterni (Supabase, Workers, Stream, ecc.)
  if (PASSTHROUGH_HOSTS.some((h) => url.hostname.endsWith(h))) {
    return; // lascia gestire al browser direttamente
  }

  // Solo same-origin da qui in poi
  if (url.origin !== self.location.origin) return;

  // HTML (navigazioni e *.html): network-first
  const isHTML =
    req.mode === 'navigate' ||
    url.pathname.endsWith('.html') ||
    url.pathname === '/';

  if (isHTML) {
    event.respondWith(networkFirst(req));
    return;
  }

  // Asset statici (icone, manifest, css/js futuri): cache-first
  event.respondWith(cacheFirst(req));
});

async function networkFirst(req) {
  try {
    const resp = await fetch(req);
    // Aggiorna cache silenziosamente (best-effort)
    if (resp.ok) {
      const cache = await caches.open(CACHE_STATIC);
      cache.put(req, resp.clone()).catch(() => {});
    }
    return resp;
  } catch (e) {
    // Offline: prova cache
    const cached = await caches.match(req);
    if (cached) return cached;
    // Fallback HTML minimo offline
    return new Response(
      '<!doctype html><meta charset="utf-8"><title>Offline</title>' +
      '<style>body{font-family:system-ui;padding:2rem;text-align:center;color:#1a1a2e}</style>' +
      '<h1>🧗 KataClimb</h1><p>Sei offline. Riprova quando torna la rete.</p>',
      { headers: { 'content-type': 'text/html; charset=utf-8' } }
    );
  }
}

async function cacheFirst(req) {
  const cached = await caches.match(req);
  if (cached) return cached;
  try {
    const resp = await fetch(req);
    if (resp.ok) {
      const cache = await caches.open(CACHE_STATIC);
      cache.put(req, resp.clone()).catch(() => {});
    }
    return resp;
  } catch (e) {
    // Niente cache, niente rete → errore
    return new Response('Offline', { status: 503 });
  }
}

/* ─── PUSH (predisposto Step 4) ───────────────────────────────────── */
self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'KataClimb', body: event.data?.text() || '' };
  }

  const title = data.title || 'KataClimb';
  const options = {
    body:    data.body || '',
    icon:    data.icon || '/favicon-192x192.png',
    badge:   '/favicon-192x192.png',
    tag:     data.tag  || 'kataclimb-default',
    data:    data.data || { url: '/portale.html' },
    requireInteraction: !!data.requireInteraction,
    silent:  !!data.silent,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

/* ─── NOTIFICATION CLICK ──────────────────────────────────────────── */
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/portale.html';

  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Se c'è già una finestra aperta della PWA, le do focus
    for (const c of all) {
      if (c.url.includes(self.location.origin) && 'focus' in c) {
        try { await c.navigate(url); } catch (e) { /* ok, alcuni browser non supportano */ }
        return c.focus();
      }
    }
    // Altrimenti apri nuova
    if (self.clients.openWindow) {
      return self.clients.openWindow(url);
    }
  })());
});

/* ─── MESSAGE (predisposto per skip waiting forzato lato app) ────── */
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
