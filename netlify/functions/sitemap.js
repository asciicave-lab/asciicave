// Genera /sitemap.xml al vuelo a partir de las novelas aprobadas en Supabase.
// No hace falta ninguna clave secreta: usa la misma anon key pública que ya
// va incluida en index.html (protegida por Row Level Security, no por ser secreta).
const SUPABASE_URL = "https://bqsntjnnpewwhgwulfzw.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_R0fpavnFI-BGMTpZIO40yw_z-3DdqRw";
const SITE_URL = "https://asciicave.com";

// Debe coincidir con GENRES en index.html. Si añades/quitas géneros ahí,
// actualízalo también aquí para que salgan sus páginas de /explorar/<genero>.
const GENRES = [
  "Acción", "Aventura", "Comedia", "Drama", "Fantasía", "Ciencia ficción",
  "Terror", "Misterio", "Romance", "Psicológico", "Histórico", "Deporte",
  "Recuentos de la vida", "Tragedia", "LitRPG", "Wuxia / Cultivo", "Sátira",
  "Contemporáneo", "Yaoi (BL)", "Yuri (GL)", "Harem", "Shounen", "Seinen", "Josei"
];

function xmlEscape(s) {
  return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}
function urlEntry(loc, lastmod, changefreq, priority) {
  let xml = `  <url>\n    <loc>${xmlEscape(loc)}</loc>\n`;
  if (lastmod) xml += `    <lastmod>${String(lastmod).slice(0, 10)}</lastmod>\n`;
  if (changefreq) xml += `    <changefreq>${changefreq}</changefreq>\n`;
  if (priority) xml += `    <priority>${priority}</priority>\n`;
  xml += `  </url>\n`;
  return xml;
}

exports.handler = async function () {
  let novels = [];
  try {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/novels?select=id,reviewed_at,created_at,chapters(idx,created_at)&status=eq.aprobada&order=id.asc`,
      { headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } }
    );
    if (res.ok) novels = await res.json();
  } catch (e) {
    // Si Supabase no responde, se sirve igualmente el sitemap con las
    // páginas fijas de abajo, en vez de devolver un error 500.
  }

  let xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n`;
  xml += urlEntry(`${SITE_URL}/`, null, "daily", "1.0");
  xml += urlEntry(`${SITE_URL}/explorar`, null, "daily", "0.9");
  xml += urlEntry(`${SITE_URL}/rankings`, null, "daily", "0.8");
  xml += urlEntry(`${SITE_URL}/escribir`, null, "monthly", "0.6");
  xml += urlEntry(`${SITE_URL}/terminos.html`, null, "yearly", "0.3");
  xml += urlEntry(`${SITE_URL}/privacidad.html`, null, "yearly", "0.3");
  GENRES.forEach((g) => {
    xml += urlEntry(`${SITE_URL}/explorar/${encodeURIComponent(g)}`, null, "daily", "0.7");
  });
  novels.forEach((n) => {
    const lastmod = n.reviewed_at || n.created_at;
    xml += urlEntry(`${SITE_URL}/novela/${n.id}`, lastmod, "weekly", "0.7");
    (n.chapters || [])
      .slice()
      .sort((a, b) => a.idx - b.idx)
      .forEach((c) => {
        xml += urlEntry(`${SITE_URL}/novela/${n.id}/capitulo/${c.idx + 1}`, c.created_at, "monthly", "0.5");
      });
  });
  xml += `</urlset>\n`;

  return {
    statusCode: 200,
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
    },
    body: xml,
  };
};
