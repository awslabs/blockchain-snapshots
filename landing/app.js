// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
'use strict';

// State: every catalog entry, flattened and tagged with its region and bucket.
let ALL = [];
// Regions are loaded from config/regions.json, the same active-region registry
// consumed by snapshot.sh. Only entries with a catalog URL are active.
let REGIONS = [];

const $ = (id) => document.getElementById(id);
const regionSel = $('region-select');
const chainSel = $('chain-select');
const statusEl = $('status');
const resultsEl = $('results');

// Display names for the overview. Unknown values fall back to the raw value.
const CHAIN_NAMES = { ethereum: 'Ethereum', robinhood: 'Robinhood Chain', solana: 'Solana' };
const REGION_NAMES = {
  'us-east-1': 'US East (N. Virginia)',
  'us-west-2': 'US West (Oregon)',
  'eu-west-1': 'Europe (Ireland)',
  'eu-central-1': 'Europe (Frankfurt)',
  'ap-northeast-1': 'Asia Pacific (Tokyo)',
  'ap-southeast-1': 'Asia Pacific (Singapore)',
};

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

// ["a", "b", "c"] -> "a, b, or c"
function joinList(items, conj) {
  if (items.length < 3) return items.join(` ${conj} `);
  return `${items.slice(0, -1).join(', ')}, ${conj} ${items[items.length - 1]}`;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort();
}

// Catalog values end up in copy-paste shell commands. Only characters that are
// safe unquoted in a shell are allowed; anything else (spaces, quotes, ;, $,
// backticks) means no command is shown, rather than trying to escape it.
const SHELL_SAFE = /^[A-Za-z0-9._\/-]+$/;
function shellSafe(...values) {
  return values.every((v) => typeof v === 'string' && SHELL_SAFE.test(v));
}

// The landing page never decides the delivery method. snapshot.sh resolves the
// stable catalog ID at execution time, normalizes catalog v1/v2, and dispatches
// to the declared delivery protocol. The command therefore stays current even
// if this browser tab has been open while a newer snapshot was published.
function commandFor(s) {
  const id = s.id || `${s.blockchain}-${s.network}-${s.client}`; // v1 adapter
  const out = `/data/${id}`;
  if (!shellSafe(id, s.region, out)) return null;
  return `sudo ./snapshot.sh --snapshot ${id} --region ${s.region} --out ${out} --install-deps`;
}

function codeBlock(text) {
  return `<div class="codeblock"><pre><code>${esc(text)}</code></pre>` +
    `<button type="button" class="copy" aria-label="Copy command">Copy</button></div>`;
}

// Load the active-region registry published with this landing page. This is
// also snapshot.sh's canonical discovery source; adding a region is data-only.
async function loadRegions() {
  const res = await fetch('./config/regions.json', { cache: 'no-cache' });
  if (!res.ok) throw new Error(`config/regions.json HTTP ${res.status}`);
  const doc = await res.json();
  return (doc.regions || []).filter((r) => r.code && (r.catalog_url || r.catalogUrl));
}

function catalogUrlFor(region) {
  return region.catalog_url || region.catalogUrl;
}

// Fetch every region's catalog.json in parallel; tolerate failures.
async function loadCatalogs() {
  const settled = await Promise.allSettled(
    REGIONS.map(async (r) => {
      // Timeout so one black-holing endpoint can't hold the whole page at
      // "Loading…" (init awaits allSettled before rendering anything).
      const res = await fetch(catalogUrlFor(r), { mode: 'cors', signal: AbortSignal.timeout(10000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const cat = await res.json();
      const region = cat.region || r.code;
      return (cat.snapshots || []).map((s) => ({ ...s, region }));
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

// Keep the overview (chains, regions) in step with what the catalogs serve.
function renderOverview() {
  const chains = uniqueSorted(ALL.map((s) => CHAIN_NAMES[s.blockchain] || s.blockchain));
  if (chains.length) $('fact-chains').textContent = chains.join(', ');

  const codes = REGIONS.map((r) => r.code);
  if (codes.length) {
    $('fact-regions').textContent = codes.map((c) => REGION_NAMES[c] || c).join(', ');
    document.querySelectorAll('[data-region-codes]').forEach((el) => {
      el.textContent = joinList(codes, 'or');
    });
  }
}

// Human-readable label for a region's <option>: "us-east-1 (N. Virginia)".
// The short location is the parenthetical from REGION_NAMES ("US East
// (N. Virginia)" -> "N. Virginia"); unknown codes show the bare code.
function regionLabel(code) {
  const full = REGION_NAMES[code];
  const m = full && /\(([^)]+)\)/.exec(full);
  return m ? `${code} (${m[1]})` : code;
}

function populateFilters() {
  const regions = uniqueSorted(REGIONS.map((r) => r.code));
  regionSel.innerHTML =
    `<option value="">All regions</option>` +
    regions.map((r) => `<option value="${esc(r)}">${esc(regionLabel(r))}</option>`).join('');

  const chains = uniqueSorted(ALL.map((s) => s.blockchain));
  chainSel.innerHTML =
    `<option value="">All blockchains</option>` +
    chains.map((c) => `<option value="${esc(c)}">${esc(CHAIN_NAMES[c] || c)}</option>`).join('');
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
      // Human label, e.g. "us-east-1 · ethereum · mainnet · geth"
      const label = `${esc(s.region)} · ${esc(s.blockchain)} · ${esc(s.network)} · ${esc(s.client)}`;
      const block = esc(s.latest_block ?? s.block ?? '—');
      const cmd = commandFor(s);
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
        <span class="label">command</span>
        ${cmd ? codeBlock(cmd) : '<p class="empty">No command available for this snapshot.</p>'}
      </article>`;
    })
    .join('');
}

function flash(button, text) {
  button.textContent = text;
  clearTimeout(button.flashTimer);
  button.flashTimer = setTimeout(() => { button.textContent = 'Copy'; }, 1500);
}

// Copy buttons, for both the Get started steps and each snapshot's command.
document.addEventListener('click', async (event) => {
  const button = event.target.closest('button.copy');
  if (!button) return;
  const code = button.parentElement.querySelector('code');
  try {
    await navigator.clipboard.writeText(code.textContent);
    flash(button, 'Copied');
  } catch {
    // No clipboard access (e.g. not a secure context): select the text instead.
    const range = document.createRange();
    range.selectNodeContents(code);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    flash(button, 'Selected');
  }
});

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
  renderOverview();
  render();
})();
