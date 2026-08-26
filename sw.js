// Service worker de AsciiCave — cachea solo el "cascarón" de la app
// (HTML, manifest, iconos) para que se pueda instalar y abrir sin
// conexión. Todo lo demás (Supabase, fuentes, anuncios, analítica)
// se deja pasar directo a la red, nunca se cachea, para no servir
// datos desactualizados de novelas/capítulos/foro.
const CACHE_NAME = 'asciicave-shell-v1';
const SHELL_FILES = ['/', '/index.html', '/manifest.json', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === 'navigate') {
    event.respondWith(fetch(req).catch(() => caches.match('/index.html')));
    return;
  }
  event.respondWith(caches.match(req).then((cached) => cached || fetch(req)));
});
