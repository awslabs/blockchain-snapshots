'use strict';

// State: every catalog entry, flattened + tagged with the region it came from.
let ALL = [];
// Regions with a deployed catalog endpoint (per-env, generated at deploy). Any
// entry without a catalogUrl is dropped on load, so the page only ever lists
// regions that can actually serve snapshots.
let REGIONS = [];

const $ = (id) => document.getElementById(id);
const regionSel = $('region-select');
const chainSel = $('chain-select');
const statusEl = $('status');
const resultsEl = $('results');

// HTML-escape every catalog-derived string before interpolating into markup.
// The catalog is producer-controlled today, but this page ships in the public
// repo where anyone points it at THEIR catalog — unescaped fields would be
// stored XSS there. Covers text and double-quoted attribute contexts.
function esc(v) {
  return String(v)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function fmtBytes(n) {
  if (!Number.isFinite(n)) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

// Load the per-environment catalog endpoints (generated at deploy by
// build-endpoints.sh; gitignored so env-specific URLs are never committed).
async function loadRegions() {
  const res = await fetch('./catalog-endpoints.json', { cache: 'no-cache' });
  if (!res.ok) throw new Error(`catalog-endpoints.json HTTP ${res.status} — run build-endpoints.sh first`);
  const doc = await res.json();
  return (doc.regions || []).filter((r) => r.code && r.catalogUrl);
}

// Fetch every region's catalog.json in parallel; tolerate failures.
async function loadCatalogs() {
  const settled = await Promise.allSettled(
    REGIONS.map(async (r) => {
      // Timeout so one black-holing endpoint can't hold the whole page at
      // "Loading…" (init awaits allSettled before rendering anything).
      const res = await fetch(r.catalogUrl, { mode: 'cors', signal: AbortSignal.timeout(10000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const cat = await res.json();
      const region = cat.region || r.code;
      return (cat.snapshots || []).map((s) => ({
        ...s,
        region,
        // Trust the catalog's self-describing url; only synthesize as a fallback.
        url: s.url || (cat.base_url ? `${cat.base_url}/${s.key}` : s.key),
      }));
    })
  );

  const rows = [];
  const failures = [];
  settled.forEach((r, i) => {
    if (r.status === 'fulfilled') rows.push(...r.value);
    else failures.push(`${REGIONS[i].code} (${r.reason.message})`);
  });

  // Count regions that actually returned data, not merely attempted.
  const parts = [`Loaded ${plural(rows.length, 'snapshot')} from ${plural(REGIONS.length - failures.length, 'region')}.`];
  if (failures.length) parts.push(`Failed: ${failures.join(', ')}.`);
  statusEl.textContent = parts.join(' ');
  return rows;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort();
}

function populateFilters() {
  const regions = uniqueSorted(REGIONS.map((r) => r.code));
  regionSel.innerHTML =
    `<option value="">All regions</option>` +
    regions.map((r) => `<option value="${esc(r)}">${esc(r)}</option>`).join('');

  const chains = uniqueSorted(ALL.map((s) => s.blockchain));
  chainSel.innerHTML =
    `<option value="">All blockchains</option>` +
    chains.map((c) => `<option value="${esc(c)}">${esc(c)}</option>`).join('');
}

function render() {
  const region = regionSel.value;
  const chain = chainSel.value;

  const rows = ALL.filter(
    (s) => (!region || s.region === region) && (!chain || s.blockchain === chain)
  ).sort((a, b) =>
    `${a.region} ${a.blockchain} ${a.network} ${a.client}`.localeCompare(
      `${b.region} ${b.blockchain} ${b.network} ${b.client}`
    )
  );

  if (!rows.length) {
    resultsEl.innerHTML = `<p class="empty">No snapshots match.</p>`;
    return;
  }

  resultsEl.innerHTML = rows
    .map((s) => {
      // Human label, e.g. "us-east-1 · ethereum · sepolia · geth"
      const label = `${esc(s.region)} · ${esc(s.blockchain)} · ${esc(s.network)} · ${esc(s.client)}`;
      const block = esc(s.latest_block ?? s.block ?? '—');
      return `
      <article class="card">
        <div class="card-head">
          <h3>${label}</h3>
          <span class="badge ${s.mode === 'remint' ? 'remint' : 'mirror'}">${esc(s.mode || 'mirror')}</span>
        </div>
        <dl class="meta">
          <div><dt>block</dt><dd>${block}</dd></div>
          <div><dt>size</dt><dd>${fmtBytes(Number(s.size_bytes))}</dd></div>
        </dl>
        <label class="urlrow">
          <span>snapshot URL</span>
          <input type="text" readonly value="${esc(s.url)}" onclick="this.select()" />
        </label>
        ${
          s.manifest_url
            ? `<label class="urlrow"><span>download manifest</span>
                 <input type="text" readonly value="${esc(s.manifest_url)}" onclick="this.select()" /></label>`
            : ''
        }
      </article>`;
    })
    .join('');
}

regionSel.addEventListener('change', render);
chainSel.addEventListener('change', render);

(async function init() {
  statusEl.textContent = 'Loading…';
  try {
    REGIONS = await loadRegions();
  } catch (e) {
    statusEl.textContent = `Could not load region list: ${e.message}`;
    return;
  }
  ALL = await loadCatalogs();
  populateFilters();
  render();
})();
