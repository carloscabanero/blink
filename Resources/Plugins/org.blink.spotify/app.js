// Adapted from Wink’s Spotify plugin (GPL-3.0): https://github.com/myneid/wink-spotify
'use strict';
const $ = id => document.getElementById(id), api = blink.spotify;
let selectedDevice = null;
let artist = null, album = null, history = [], loadGeneration = 0;
let playback = null, view = 'search', offset = 0, artwork = '', busy = false, connected = false;
const request = (verb, path, query = {}, body) => api.request(verb, path, query, body);
const report = error => { $('status').textContent = error?.message || String(error); };
async function run(action) { try { $('status').textContent = ''; await action(); } catch (error) { report(error); } }
function session(value) { connected = value; $('setup').hidden = value; $('app').hidden = !value; $('disconnect').hidden = !value; $('connection').textContent = value ? 'Connected' : 'Disconnected'; }
const time = ms => `${Math.floor((ms || 0) / 60000)}:${String(Math.floor((ms || 0) / 1000) % 60).padStart(2, '0')}`;
function deviceQuery() { const id = $('devices').value; if (!id) throw new Error('Open Spotify on a device, then refresh the device list.'); return {device_id: id}; }
async function command(path, verb = 'PUT', query = {}, body) { await request(verb, '/me/player' + path, {...deviceQuery(), ...query}, body); await refresh(); }
async function refresh() {
  if (!connected || busy) return;
  busy = true;
  try {
    const state = await request('GET', '/me/player'); playback = state;
    const track = state?.item;
    $('title').textContent = track?.name || 'No active playback';
    $('artist').textContent = track ? `${(track.artists || []).map(a => a.name).join(', ')} — ${track.album?.name || ''}` : 'Choose a Spotify Connect device, then select a song.';
    $('tracklink').hidden = !track?.external_urls?.spotify;
    if (track?.external_urls?.spotify) $('tracklink').href = track.external_urls.spotify;
    $('toggle').textContent = state?.is_playing ? 'Pause' : 'Play';
    $('progress').textContent = `${time(state?.progress_ms)} / ${time(track?.duration_ms)}`;
    $('seek').max = track?.duration_ms || 1; $('seek').value = state?.progress_ms || 0;
    $('volume').value = state?.device?.volume_percent ?? 50;
    $('shuffle').textContent = `Shuffle ${state?.shuffle_state ? 'on' : 'off'}`;
    $('repeat').textContent = `Repeat ${state?.repeat_state || 'off'}`;
    const image = track?.album?.images?.[0]?.url || '';
    if (image !== artwork) { artwork = image; $('art').hidden = true; if (image) { const data = await api.artwork(image); if (artwork === image) { $('art').src = data; $('art').hidden = false; } } }
  } finally { busy = false; }
}
async function devices() {
  const data = await request('GET', '/me/player/devices');
  const available = data?.devices || [];
  $('devices').replaceChildren();
  for (const device of available) {
    if (!device.id || device.is_restricted) continue;
    const option = document.createElement('option');
    option.value = device.id;
    option.textContent = `${device.name}${device.is_active ? ' • active' : ''}`;
    $('devices').append(option);
  }
  const active = available.find(device => device.is_active && !device.is_restricted)?.id;
  $('devices').value = selectedDevice || active || '';
  if ($('devices').selectedIndex < 0) $('devices').selectedIndex = 0;
  selectedDevice = $('devices').selectedIndex < 0 ? null : $('devices').value;
}
function button(text, action) { const b = document.createElement('button'); b.textContent = text; b.onclick = () => run(action); return b; }
function navigate(next, title, item = null) {
  history.push({view, offset, artist, album, title:$('heading').textContent, query:$('query').value, type:$('searchtype').value, group:$('release-group').value});
  view = next; offset = 0;
  if (next === 'artist') { artist = item; album = null; $('release-group').value = 'album'; }
  if (next === 'album') album = item;
  $('heading').textContent = title;
  return load();
}
function row(item, kind, position) {
  const track = item.track || item.item || item;
  if (!track) return;
  const div = document.createElement('div'); div.className = 'row';
  const description = document.createElement('div'); description.className = 'description'; description.textContent = track.name || 'Unavailable';
  const sub = document.createElement('small');
  sub.textContent = kind === 'artist' ? 'Artist' : kind === 'album' ? `${track.release_date || ''} · ${track.total_tracks ?? '?'} tracks · ${track.album_group || track.album_type || 'album'}` : (track.artists || []).map(a => a.name).join(', ') || track.owner?.display_name || '';
  if (view === 'album' && kind === 'track') sub.textContent = `Disc ${track.disc_number || 1} · ${track.track_number || position + 1} · ${time(track.duration_ms)}`;
  description.append(sub); div.append(description);
  if (kind === 'artist') div.append(button('Albums →', () => navigate('artist', track.name, track)));
  if (kind === 'album') div.append(button('Tracks →', () => navigate('album', track.name, track)));
  if (kind === 'playlist') div.append(button('Open', () => navigate(track.id, track.name)));
  if (track.uri && kind !== 'artist') {
    const body = kind === 'playlist' || kind === 'album' ? {context_uri:track.uri} : view === 'album' ? {context_uri:album.uri, offset:{position}} : {uris:[track.uri]};
    div.append(button(kind === 'album' ? 'Play album' : 'Play', () => command('/play', 'PUT', {}, body)));
    if (kind === 'track') div.append(button('+ Queue', () => command('/queue', 'POST', {uri:track.uri})));
  }
  const href = track.external_urls?.spotify;
  if (href && href.startsWith('https://open.spotify.com/')) { const a = document.createElement('a'); a.href = href; a.textContent = 'Spotify ↗'; a.target = '_blank'; a.rel = 'noopener'; div.append(a); }
  $('results').append(div);
}
async function load(append = false) {
  const generation = ++loadGeneration;
  $('back').hidden = !history.length;
  $('discography').hidden = view !== 'artist';
  $('playalbum').hidden = view !== 'album';
  $('more').hidden = true;
  if (!append) $('results').replaceChildren();
  let data, items, kind = 'track'; const query = {limit:'10', offset:String(offset)};
  if (view === 'search') {
    const q = $('query').value.trim(); if (!q) return;
    kind = $('searchtype').value;
    data = (await request('GET', '/search', {...query, q, type:kind}))?.[kind + 's'];
  } else if (view === 'artist') {
    kind = 'album';
    data = await request('GET', `/artists/${artist.id}/albums`, {...query, include_groups:$('release-group').value});
  } else if (view === 'album') data = await request('GET', `/albums/${album.id}/tracks`, query);
  else if (view === 'library') data = await request('GET', '/me/tracks', query);
  else if (view === 'playlists') { data = await request('GET', '/me/playlists', query); kind = 'playlist'; }
  else if (view === 'queue') { const queue = await request('GET', '/me/player/queue'); items = queue?.queue || []; }
  else data = await request('GET', `/playlists/${view}/items`, query);
  if (generation !== loadGeneration) return;
  items = items || data?.items || []; items.forEach((item, index) => row(item, kind, offset + index));
  if (!items.length && !append) $('results').textContent = 'No items available.';
  $('more').hidden = !data?.next;
}
$('back').onclick = () => run(async () => {
  const previous = history.pop(); if (!previous) return;
  ({view, artist, album} = previous); offset = 0;
  $('query').value = previous.query; $('searchtype').value = previous.type; $('release-group').value = previous.group;
  $('heading').textContent = previous.title;
  await load();
});
$('release-group').onchange = () => { offset = 0; run(() => load()); };
$('playalbum').onclick = () => run(() => command('/play', 'PUT', {}, {context_uri:album.uri}));
$('login').onclick = () => run(async () => { $('login').disabled = true; try { await api.login($('client').value.trim()); session(true); await devices(); await refresh(); } finally { $('login').disabled = false; } });
$('disconnect').onclick = () => run(async () => { selectedDevice = null; await api.logout(); session(false); $('art').removeAttribute('src'); $('results').replaceChildren(); artwork = ''; playback = null; });
$('toggle').onclick = () => run(() => command(playback?.is_playing ? '/pause' : '/play'));
$('next').onclick = () => run(() => command('/next', 'POST'));
$('previous').onclick = () => run(() => command('/previous', 'POST'));
$('shuffle').onclick = () => run(() => command('/shuffle', 'PUT', {state: String(!playback?.shuffle_state)}));
$('repeat').onclick = () => run(() => command('/repeat', 'PUT', {state: ({off:'context',context:'track',track:'off'})[playback?.repeat_state || 'off']}));
$('volume').onchange = () => run(() => command('/volume', 'PUT', {volume_percent: $('volume').value}));
$('seek').onchange = () => run(() => command('/seek', 'PUT', {position_ms: $('seek').value}));
$('devices').onchange = () => run(async () => { if ($('devices').value) { selectedDevice = $('devices').value; await request('PUT', '/me/player', {}, {device_ids:[$('devices').value], play:false}); await refresh(); } });
$('refresh').onclick = () => run(async () => { await devices(); await refresh(); });
$('searchform').onsubmit = event => { event.preventDefault(); view = 'search'; offset = 0; history = []; artist = album = null; $('heading').textContent = 'Search results'; run(() => load()); };
document.querySelectorAll('[data-view]').forEach(b => { b.onclick = () => { view = b.dataset.view; offset = 0; history = []; artist = album = null; $('heading').textContent = b.textContent; run(() => load()); }; });
$('more').onclick = () => run(async () => { const previous = offset; const generation = loadGeneration; offset += 10; $('more').disabled = true; try { await load(true); } catch (error) { if (loadGeneration === generation + 1) offset = previous; throw error; } finally { $('more').disabled = false; } });
document.addEventListener('keydown', event => {
  if (!connected || event.metaKey || event.ctrlKey || event.altKey || ['INPUT','TEXTAREA','SELECT','BUTTON'].includes(event.target.tagName)) return;
  const actions = {' ': 'toggle', n:'next', p:'previous'};
  if (actions[event.key]) { event.preventDefault(); $(actions[event.key]).click(); }
  if (event.key === '/') { event.preventDefault(); $('query').focus(); }
});
setInterval(() => { if (connected && !document.hidden) run(refresh); }, 10000);
run(async () => { const info = await blink.host.info(); if (!info.capabilities.includes('spotify')) throw new Error('This host does not provide the Spotify capability. Use the bundled Spotify app.'); session((await api.status()).connected); if (connected) { await devices(); await refresh(); } });
