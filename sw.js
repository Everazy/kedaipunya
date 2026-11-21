/* Service worker kasir: menyimpan halaman agar bisa dibuka saat internet putus.
   Letakkan di folder yang sama dengan index.html. Permintaan ke Supabase tidak disentuh. */
const C = "kasir-v4";
const SHELL = ["./", "index.html", "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(C)
      .then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== "GET" || u.hostname.endsWith("supabase.co")) return;
  e.respondWith(
    fetch(r)
      .then(res => {
        if (res.ok) { const cp = res.clone(); caches.open(C).then(c => c.put(r, cp)); }
        return res;
      })
      .catch(() =>
        caches.match(r).then(m => {
          if (m) return m;
          if (r.mode === "navigate") return caches.match("index.html").then(x => x || caches.match("./")).then(x => x || Response.error());
          return Response.error();
        })
      )
  );
});
