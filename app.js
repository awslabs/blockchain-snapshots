// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
'use strict';

// The registry published beside this page is canonical; the absolute URL covers
// local previews and hosts that don't carry config/regions.json.
const REGISTRY_URLS = [
  './config/regions.json',
  'https://awslabs.github.io/blockchain-snapshots/config/regions.json',
];

// Allowlist of chains this page lists, keyed by the catalog's `blockchain` value.
// Entries for any other chain are dropped as catalogs load; the catalogs are unchanged.
const ENABLED_CHAINS = { ethereum: 'Ethereum', solana: 'Solana' };
const CLIENT_NAMES = { geth: 'Geth', nethermind: 'Nethermind', reth: 'Reth', agave: 'Agave' };
const NETWORK_NAMES = { mainnet: 'Mainnet', hoodi: 'Hoodi' };
const VERSION_LABELS = { solana: 'Slot' };
const REGION_NAMES = {
  'us-east-1': 'N. Virginia',
  'us-west-2': 'Oregon',
  'eu-west-1': 'Ireland',
  'eu-central-1': 'Frankfurt',
  'ap-northeast-1': 'Tokyo',
  'ap-southeast-1': 'Singapore',
};
const PROTOCOLS = {
  'tar-zstd-seekable-v1': { pill: 'Seekable', cls: '' },
  'tar-zstd-stream-v1': { pill: 'Stream', cls: 'pill--stream' },
  'archive-set-v1': { pill: 'Archive set', cls: 'pill--archive' },
};

const $ = (id) => document.getElementById(id);
// Catalogs are re-checked on this cadence while the tab is visible. Requests
// revalidate with ETags, so an unchanged catalog costs a 304.
const REFRESH_MS = 5 * 60 * 1000;
const CLOCK_MS = 30 * 1000;

const state = {
  regions: [], catalogs: new Map(), failures: [], region: '', chain: '',
  signature: '', checkedAt: 0, attemptedAt: 0, refreshing: false, timer: 0,
};

function isEnabledChain(blockchain) {
  return typeof blockchain === 'string' && Object.hasOwn(ENABLED_CHAINS, blockchain);
}

// Every catalog-derived string is escaped before it reaches markup.
function esc(v) {
  return String(v)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Catalog values end up in copy-paste shell commands: anything outside this set
// means no command is shown, rather than trying to quote it.
const SHELL_SAFE = /^[A-Za-z0-9._\/-]+$/;
const shellSafe = (...values) => values.every((v) => typeof v === 'string' && SHELL_SAFE.test(v));

const titleCase = (s) => String(s).charAt(0).toUpperCase() + String(s).slice(1);
const clientName = (c) => CLIENT_NAMES[c] || titleCase(c);
const networkName = (n) => NETWORK_NAMES[n] || titleCase(n);

function joinList(items, conj) {
  if (items.length < 3) return items.join(` ${conj} `);
  return `${items.slice(0, -1).join(', ')}, ${conj} ${items[items.length - 1]}`;
}

function fmtBytes(n) {
  if (!Number.isFinite(n)) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;
}

function fmtVersion(v) {
  if (typeof v === 'number' && Number.isInteger(v)) return v.toLocaleString('en-US');
  return v == null ? '—' : String(v);
}

function relTime(iso) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return '—';
  const s = Math.max(0, (Date.now() - t) / 1000);
  const steps = [[60, 'second'], [60, 'minute'], [24, 'hour'], [30, 'day'], [12, 'month']];
  let value = s;
  for (const [size, unit] of steps) {
    if (value < size) {
      const n = Math.max(1, Math.floor(value));
      return unit === 'second' ? 'just now' : `${n} ${unit}${n === 1 ? '' : 's'} ago`;
    }
    value /= size;
  }
  const n = Math.floor(value);
  return `${n} year${n === 1 ? '' : 's'} ago`;
}

// Mirrors snapshot-catalog.py: catalog v2 declares the protocol; v1 is inferred.
function protocolFor(s) {
  if (s.delivery && typeof s.delivery.protocol === 'string') return s.delivery.protocol;
  if (s.mode === 'remint') return 'tar-zstd-seekable-v1';
  if (s.blockchain === 'solana') return 'archive-set-v1';
  return 'tar-zstd-stream-v1';
}

function normalize(s, region) {
  const version = s.version && typeof s.version === 'object' ? s.version.display : (s.latest_block ?? s.block);
  return {
    id: s.id || `${s.blockchain}-${s.network}-${s.client}`,
    blockchain: s.blockchain,
    network: s.network,
    client: s.client,
    version,
    sizeBytes: Number(s.size_bytes),
    updated: s.last_modified,
    protocol: protocolFor(s),
    incremental: s.incremental && typeof s.incremental === 'object' ? s.incremental : null,
    region,
  };
}

// The page never decides the delivery method: snapshot.sh resolves the stable ID
// again when it runs, so a long-open tab can't produce a stale command.
function commandFor(s) {
  const out = `/data/${s.id}`;
  if (!shellSafe(s.id, out)) return null;
  return `./snapshot.sh --snapshot ${s.id} --out ${out}`;
}

function codeBlock(text, label = 'bash') {
  return `<div class="code"><div class="code__bar"><span class="caption">${esc(label)}</span>` +
    `<button type="button" class="copy">Copy</button></div><pre><code>${esc(text)}</code></pre></div>`;
}

async function fetchJson(url, ms) {
  const res = await fetch(url, { cache: 'no-cache', signal: AbortSignal.timeout(ms) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

// Remembers which registry answered, so later refreshes skip a known 404.
let registryUrl = null;
async function loadRegions() {
  let lastError = new Error('no active Regions');
  const urls = registryUrl ? [registryUrl, ...REGISTRY_URLS.filter((u) => u !== registryUrl)] : REGISTRY_URLS;
  for (const url of urls) {
    try {
      const doc = await fetchJson(url, 8000);
      const regions = (doc.regions || []).filter((r) => r.code && (r.catalog_url || r.catalogUrl));
      if (regions.length) {
        registryUrl = url;
        return regions;
      }
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}

async function loadCatalogs(regions) {
  const settled = await Promise.allSettled(regions.map(async (r) => {
    const cat = await fetchJson(r.catalog_url || r.catalogUrl, 10000);
    const rows = (cat.snapshots || [])
      .filter((s) => isEnabledChain(s?.blockchain))
      .map((s) => normalize(s, r.code))
      .sort((a, b) => a.id.localeCompare(b.id));
    return { code: r.code, generated: cat.generated_at, rows };
  }));
  const catalogs = new Map();
  const failures = [];
  settled.forEach((result, i) => {
    if (result.status === 'fulfilled') catalogs.set(result.value.code, result.value);
    else failures.push({ code: regions[i].code, reason: result.reason.message });
  });
  return { catalogs, failures };
}

// Only what the page shows; `generated_at` changes on every publish even when nothing else does.
function signature() {
  return JSON.stringify([...state.catalogs.values()].map((c) => [c.code, c.rows.map((s) => [
    s.id, s.version, s.sizeBytes, s.updated, s.protocol, s.incremental?.slot, s.incremental?.size_bytes,
  ])]));
}

function allRows() {
  return [...state.catalogs.values()].flatMap((c) => c.rows);
}

function renderOverview() {
  const rows = allRows();
  const chains = [...new Set(rows.map((s) => ENABLED_CHAINS[s.blockchain]))].sort();
  const clients = [...new Set(rows.map((s) => clientName(s.client)))].sort();
  if (chains.length) $('fact-chains').textContent = chains.join(', ');
  if (clients.length) $('fact-clients').textContent = clients.join(', ');
  const codes = state.regions.map((r) => r.code);
  document.querySelectorAll('[data-region-list]').forEach((el) => {
    el.innerHTML = codes.map((c) => `<span>${esc(c)}</span>`).join(', ');
  });
  document.querySelectorAll('[data-region-codes]').forEach((el) => { el.textContent = joinList(codes, 'or'); });
}

// Same layout as `snapshot.sh --list`: id, protocol, version.
function renderTerminal() {
  const first = state.catalogs.get(state.regions.map((r) => r.code).find((c) => state.catalogs.has(c)));
  if (!first || !first.rows.length) return;
  const width = Math.max(...first.rows.map((s) => s.id.length));
  $('term-list').textContent = first.rows
    .map((s) => `${s.id.padEnd(width)}  ${s.protocol.padEnd(25)}  ${s.version ?? '-'}`)
    .join('\n');
  const pick = first.rows.find((s) => s.protocol === 'tar-zstd-seekable-v1') || first.rows[0];
  const cmd = commandFor(pick);
  if (cmd) $('term-cmd').textContent = cmd;
  $('term-caption').dataset.region = first.code;
}

// "Ethereum mainnet (Geth, Nethermind, Reth)" per protocol, from live data.
function renderProtocolUsers() {
  const groups = new Map();
  for (const s of allRows()) {
    const key = `${s.protocol}|${s.blockchain}|${s.network}`;
    if (!groups.has(key)) groups.set(key, new Set());
    groups.get(key).add(clientName(s.client));
  }
  document.querySelectorAll('[data-protocol-users]').forEach((cell) => {
    const protocol = cell.dataset.protocolUsers;
    const users = [...groups.entries()]
      .filter(([key]) => key.startsWith(`${protocol}|`))
      .map(([key, clients]) => {
        const [, chain, network] = key.split('|');
        return `${ENABLED_CHAINS[chain]} ${networkName(network)} (${[...clients].sort().join(', ')})`;
      });
    cell.textContent = users.length ? users.join('; ') : 'No current snapshots';
  });
}

function renderRegionControl() {
  const group = $('region-group');
  const codes = state.regions.map((r) => r.code).filter((c) => state.catalogs.has(c));
  if (!codes.includes(state.region)) state.region = codes[0] || '';
  group.innerHTML = codes.map((c) => `
    <button type="button" role="radio" data-region="${esc(c)}" aria-checked="${c === state.region}" tabindex="${c === state.region ? 0 : -1}">
      ${esc(c)}<small>${esc(REGION_NAMES[c] || '')}</small>
    </button>`).join('');
}

function renderChainSelect() {
  const chains = [...new Set(allRows().map((s) => s.blockchain))].sort();
  if (!chains.includes(state.chain)) state.chain = '';
  $('chain-select').innerHTML = `<option value="">All blockchains</option>` +
    chains.map((c) => `<option value="${esc(c)}">${esc(ENABLED_CHAINS[c])}</option>`).join('');
  $('chain-select').value = state.chain;
}

function cardFor(s) {
  const proto = PROTOCOLS[s.protocol] || { pill: s.protocol, cls: '' };
  const versionLabel = VERSION_LABELS[s.blockchain] || 'Block';
  const elsewhere = [...state.catalogs.values()]
    .filter((c) => c.code !== s.region && c.rows.some((r) => r.id === s.id))
    .map((c) => c.code);
  const extras = [];
  if (s.incremental && Number.isFinite(Number(s.incremental.slot))) {
    extras.push(`Includes an incremental snapshot to slot ${esc(Number(s.incremental.slot).toLocaleString('en-US'))} (${esc(fmtBytes(Number(s.incremental.size_bytes)))}).`);
  }
  if (s.protocol === 'tar-zstd-stream-v1' && Number.isFinite(s.sizeBytes)) {
    extras.push(`Needs about ${esc(fmtBytes(s.sizeBytes * 2))} free: 2× the download.`);
  }
  if (elsewhere.length) extras.push(`Also in ${joinList(elsewhere.map((c) => `<span>${esc(c)}</span>`), 'and')}.`);
  const cmd = commandFor(s);
  return `
    <article class="snap" data-id="${esc(s.id)}">
      <div>
        <div class="snap__title">
          <code class="snap__id">${esc(s.id)}</code>
          <span class="pill ${proto.cls}" title="${esc(s.protocol)}">${esc(proto.pill)}</span>
        </div>
        <dl class="snap__meta">
          <div><dt>Chain</dt><dd>${esc(ENABLED_CHAINS[s.blockchain])}</dd></div>
          <div><dt>Network</dt><dd>${esc(networkName(s.network))}</dd></div>
          <div><dt>Client</dt><dd>${esc(clientName(s.client))}</dd></div>
          <div><dt>${esc(versionLabel)}</dt><dd>${esc(fmtVersion(s.version))}</dd></div>
          <div><dt>Download</dt><dd>${esc(fmtBytes(s.sizeBytes))}</dd></div>
          <div><dt>Updated</dt><dd><time data-rel datetime="${esc(s.updated || '')}" title="${esc(s.updated || '')}">${esc(relTime(s.updated))}</time></dd></div>
        </dl>
        ${extras.length ? `<p class="snap__extra">${extras.join(' ')}</p>` : ''}
      </div>
      ${cmd ? codeBlock(cmd) : '<p class="empty">No command available for this snapshot.</p>'}
    </article>`;
}

// Re-rendering replaces the cards, so focus inside them is put back where it was.
function renderResults({ keepFocus = false } = {}) {
  const active = keepFocus && $('results').contains(document.activeElement) ? document.activeElement : null;
  const focusId = active?.closest('.snap')?.dataset.id;
  const focusCopy = active?.classList.contains('copy');
  const catalog = state.catalogs.get(state.region);
  const rows = (catalog ? catalog.rows : []).filter((s) => !state.chain || s.blockchain === state.chain);
  $('results').innerHTML = rows.length ? rows.map(cardFor).join('') : '<p class="empty">No snapshots match.</p>';
  if (focusId) {
    const card = [...$('results').querySelectorAll('.snap')].find((el) => el.dataset.id === focusId);
    const target = card && (focusCopy ? card.querySelector('.copy') : card);
    if (target) {
      if (!focusCopy) target.tabIndex = -1;
      target.focus({ preventScroll: true });
    }
  }
  renderStatus();
}

// The live region announces counts and failures only; timestamps live outside it.
function renderStatus() {
  const catalog = state.catalogs.get(state.region);
  const rows = (catalog ? catalog.rows : []).filter((s) => !state.chain || s.blockchain === state.chain);
  const parts = [];
  if (catalog) parts.push(`${rows.length} snapshot${rows.length === 1 ? '' : 's'} in ${state.region}`);
  parts.push(`${state.catalogs.size} of ${state.regions.length} Regions loaded`);
  let text = parts.join(' · ');
  if (state.failures.length) {
    const kept = state.failures.filter((f) => state.catalogs.has(f.code)).map((f) => f.code);
    const lost = state.failures.filter((f) => !state.catalogs.has(f.code)).map((f) => `${f.code} (${f.reason})`);
    if (kept.length) text += `. Couldn’t refresh ${joinList(kept, 'and')}; showing the last loaded data`;
    if (lost.length) text += `. Couldn’t load ${lost.join(', ')}`;
    text += '.';
  }
  if ($('status').textContent !== text) $('status').textContent = text;
}

function updateTimes() {
  document.querySelectorAll('time[data-rel]').forEach((t) => { t.textContent = relTime(t.dateTime); });
  const catalog = state.catalogs.get(state.region);
  const parts = [];
  if (catalog) parts.push(`catalog generated ${relTime(catalog.generated)}`);
  if (state.refreshing) parts.push('checking for updates…');
  else if (state.checkedAt) parts.push(`checked ${relTime(new Date(state.checkedAt).toISOString())}`);
  parts.push('refreshes every 5 minutes');
  $('freshness').textContent = ` · ${parts.join(' · ')}`;
  const term = $('term-caption');
  const first = state.catalogs.get(term.dataset.region);
  if (first) term.textContent = `Live from the ${first.code} catalog · generated ${relTime(first.generated)}`;
}

function renderAll() {
  renderOverview();
  renderTerminal();
  renderProtocolUsers();
  renderRegionControl();
  renderChainSelect();
  renderResults({ keepFocus: true });
}

function selectRegion(code, focus) {
  state.region = code;
  document.querySelectorAll('#region-group [role="radio"]').forEach((b) => {
    const on = b.dataset.region === code;
    b.setAttribute('aria-checked', String(on));
    b.tabIndex = on ? 0 : -1;
    if (on && focus) b.focus();
  });
  renderResults();
  updateTimes();
}

$('region-group').addEventListener('click', (e) => {
  const b = e.target.closest('[data-region]');
  if (b) selectRegion(b.dataset.region);
});
$('region-group').addEventListener('keydown', (e) => {
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) return;
  e.preventDefault();
  const buttons = [...document.querySelectorAll('#region-group [role="radio"]')];
  const i = buttons.findIndex((b) => b.dataset.region === state.region);
  const step = e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 1;
  selectRegion(buttons[(i + step + buttons.length) % buttons.length].dataset.region, true);
});
$('chain-select').addEventListener('change', (e) => { state.chain = e.target.value; renderResults(); updateTimes(); });
$('refresh-now').addEventListener('click', () => refresh());

// Tabs: progressive enhancement over panels that are all visible without JS.
document.querySelectorAll('[data-tabs]').forEach((tabs) => {
  const buttons = [...tabs.querySelectorAll('[role="tab"]')];
  const show = (btn, focus) => {
    buttons.forEach((b) => {
      const on = b === btn;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1;
      document.getElementById(b.getAttribute('aria-controls')).hidden = !on;
    });
    if (focus) btn.focus();
  };
  buttons.forEach((b, i) => {
    b.addEventListener('click', () => show(b));
    b.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      show(buttons[(i + (e.key === 'ArrowLeft' ? -1 : 1) + buttons.length) % buttons.length], true);
    });
  });
  show(buttons.find((b) => b.getAttribute('aria-selected') === 'true') || buttons[0]);
});

function flash(button, text) {
  button.textContent = text;
  clearTimeout(button.flashTimer);
  button.flashTimer = setTimeout(() => { button.textContent = 'Copy'; }, 1500);
}

document.addEventListener('click', async (event) => {
  const button = event.target.closest('button.copy');
  if (!button) return;
  const code = button.closest('.code').querySelector('code');
  try {
    await navigator.clipboard.writeText(code.textContent);
    flash(button, 'Copied');
  } catch {
    const range = document.createRange();
    range.selectNodeContents(code);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    flash(button, 'Selected');
  }
});

function schedule() {
  clearTimeout(state.timer);
  if (document.hidden) return;
  const wait = Math.max(0, REFRESH_MS - (Date.now() - state.attemptedAt));
  state.timer = setTimeout(refresh, wait);
}

async function refresh() {
  if (state.refreshing) return;
  state.refreshing = true;
  state.attemptedAt = Date.now();
  clearTimeout(state.timer);
  $('refresh-now').disabled = true;
  updateTimes();
  try {
    let regions = state.regions;
    try {
      regions = await loadRegions();
    } catch (e) {
      if (!regions.length) throw e;
    }
    const { catalogs, failures } = await loadCatalogs(regions);
    // A Region that fails to refresh keeps its last good catalog instead of disappearing.
    for (const f of failures) {
      if (state.catalogs.has(f.code)) catalogs.set(f.code, state.catalogs.get(f.code));
    }
    const ordered = new Map(regions.filter((r) => catalogs.has(r.code)).map((r) => [r.code, catalogs.get(r.code)]));
    state.regions = regions;
    state.catalogs = ordered;
    state.failures = failures;
    if (ordered.size) state.checkedAt = Date.now();
    const next = signature();
    if (next !== state.signature) {
      state.signature = next;
      renderAll();
    } else {
      renderStatus();
    }
  } catch (e) {
    if (!state.catalogs.size) {
      $('status').textContent = `Couldn’t load the Region registry (${e.message}). Retrying in 5 minutes; on your instance, run ./snapshot.sh --list instead.`;
      $('results').innerHTML = '';
    }
  } finally {
    state.refreshing = false;
    $('refresh-now').disabled = false;
    updateTimes();
    schedule();
  }
}

// Background tabs stop polling; coming back checks right away if the data is due.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) clearTimeout(state.timer);
  else { updateTimes(); schedule(); }
});
setInterval(() => { if (!document.hidden) updateTimes(); }, CLOCK_MS);

refresh();
