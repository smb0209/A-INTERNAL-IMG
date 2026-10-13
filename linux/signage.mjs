#!/usr/bin/env node
// A-INTERNAL-IMG 리눅스 판 — server.ps1 이 TV(MSX)에 주던 주소를 Node(의존성 없음)로 그대로 낸다.
//   node signage.mjs                 HTTP 서버 (systemd a-signage.service)
//   node signage.mjs --sync [채널]   구글 드라이브 폴더를 새 버전 폴더로 받아 current 를 바꾼다 (a-signage-sync.timer, 매일 아침)
// 설정은 환경변수: PORT, DATA_DIR, CHANNELS, DURATION, FADE_MS, KEEP_VERSIONS (deploy/a-signage.env)
//
// 채널 = 주소 첫 경로. CHANNELS=gompyo:<폴더ID>,img:<폴더ID> 이면 /gompyo/..., /img/... 가 각자 다른 드라이브 폴더를 튼다.
// 경로에 채널이 없으면 호스트 첫 이름을 본다: MSX 에 / 를 못 치는 TV 는 img.amartyyc.com 처럼 채널 이름으로 시작하는 호스트를 넣는다.
// 그것도 아니면(TV 에 IP:8080 이나 tv.amartyyc.com 만 넣은 경우) 첫 채널로 본다.
//
// 영상은 media/<채널>/<버전>/ 에 두고 list.json 이 버전이 든 주소를 낸다. 동기화로 버전이 바뀌면 주소가 달라지고,
// TV 슬라이드쇼(plugins/js/slideshow.js)가 1분마다 목록을 다시 읽다가 알아채고 새 영상으로 바꾼다.
// 이전 버전 폴더는 KEEP_VERSIONS 개까지 남겨, 바뀌는 순간 옛 주소로 받던 TV 도 끊기지 않는다.

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Readable, Transform } from 'node:stream';
import { fileURLToPath } from 'node:url';

const PORT = Number(process.env.PORT || 8080);
const DATA_DIR = path.resolve(process.env.DATA_DIR || '/var/lib/a-signage');
const DURATION = Number(process.env.DURATION || 10); // 이미지 1장 노출(초)
const FADE_MS = Number(process.env.FADE_MS || 2000);
const KEEP_VERSIONS = Math.max(2, Number(process.env.KEEP_VERSIONS || 7));

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_DIR = path.join(HERE, 'plugins'); // 저장소에 든 slideshow.html, js/slideshow.js, keep.mp4
const LIB_DIR = path.join(DATA_DIR, 'js'); // MSX 라이브러리 2개, msx.benzac.de 에서 처음 한 번 받아 둔다
const MEDIA_DIR = path.join(DATA_DIR, 'media'); // media/<채널>/<버전>/<파일>, media/<채널>/current -> <버전>
const VERSION_RE = /^\d{8}-\d{6}$/;

const IMG_EXT = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];
const VID_EXT = ['.mp4', '.mov', '.m4v', '.webm'];
const LIBS = [
  ['https://msx.benzac.de/js/jquery.min.js', 'jquery.min.js'],
  ['https://msx.benzac.de/js/tvx-plugin-ux.min.js', 'tvx-plugin-ux.min.js'],
];
const TYPES = {
  '.json': 'application/json; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.bmp': 'image/bmp',
  '.mp4': 'video/mp4',
  '.m4v': 'video/quicktime',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
};
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Range',
};
const UA = { 'User-Agent': 'Mozilla/5.0' };

const log = (msg) => console.log(msg); // journald 가 시각을 붙인다
const isVideo = (name) => VID_EXT.includes(path.extname(name).toLowerCase());
const isMedia = (name) => isVideo(name) || IMG_EXT.includes(path.extname(name).toLowerCase());

// CHANNELS=이름:폴더ID,이름:폴더ID — 이름은 주소 경로라 소문자·숫자·-·_ 만. 서버 경로와 겹치는 이름은 안 된다.
function parseChannels(spec) {
  const list = [];
  for (const part of spec.split(',').map((x) => x.trim()).filter(Boolean)) {
    const [name, folderId = ''] = part.split(':').map((x) => x.trim());
    if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(name) || ['msx', 'plugins', 'js', 'media'].includes(name)) {
      throw new Error(`CHANNELS 의 채널 이름이 잘못됨: "${name}" (소문자·숫자·-·_, msx/plugins/js/media 는 못 씀)`);
    }
    if (list.some((c) => c.name === name)) throw new Error(`CHANNELS 에 같은 이름이 두 번: ${name}`);
    list.push({ name, folderId, dir: path.join(MEDIA_DIR, name) });
  }
  if (list.length === 0) throw new Error('CHANNELS 가 비어 있음 (예: CHANNELS=gompyo:<드라이브폴더ID>)');
  return list;
}
const CHANNELS = parseChannels(process.env.CHANNELS || '');
const CHANNEL_BY_NAME = new Map(CHANNELS.map((c) => [c.name, c]));

function currentVersion(ch) {
  try {
    return fs.readlinkSync(path.join(ch.dir, 'current'));
  } catch {
    return null;
  }
}

function mediaFiles(dir) {
  try {
    return fs
      .readdirSync(dir)
      .filter(isMedia)
      .sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0));
  } catch {
    return [];
  }
}

const libsReady = () => LIBS.every(([, name]) => fs.existsSync(path.join(LIB_DIR, name)));

function lanIp() {
  const all = Object.values(os.networkInterfaces())
    .flat()
    .filter((a) => a && a.family === 'IPv4' && !a.internal)
    .map((a) => a.address);
  return all.find((a) => a.startsWith('192.168.')) || all[0] || '127.0.0.1';
}

// ----- MSX 가 읽는 JSON 3개 (server.ps1 의 Build-StartJson / Build-MenuJson / Build-ListJson) -----

// base = 'http(s)://<TV 가 접속한 host>/<채널>' — 모든 주소를 이걸로 만든다
function startJson(base) {
  return { name: 'A-INTERNAL-IMG', version: '1.0.0', parameter: `content:${base}/menu.json`, welcome: 'none' };
}

function listJson(ch) {
  const ver = currentVersion(ch);
  const items = ver
    ? mediaFiles(path.join(ch.dir, ver)).map((name) => {
        const url = `/${ch.name}/media/${encodeURIComponent(ver)}/${encodeURIComponent(name)}`;
        return isVideo(name) ? { type: 'video', url } : { type: 'image', url, duration: DURATION };
      })
    : [];
  return { fade: FADE_MS, items };
}

const PLAYER_PROPS = {
  'control:type': 'extended',
  'control:load': 'silent',
  'control:return': 'silent',
  'button:play_pause:display': 'false',
  'button:content:display': 'false',
  'button:restart:display': 'false',
  'button:prev:display': 'false',
  'button:next:display': 'false',
  'button:stop:display': 'false',
  'button:speed:display': 'false',
  'button:rotate:display': 'false',
  'button:zoom:display': 'false',
};

function menuJson(ch, origin) {
  const base = `${origin}/${ch.name}`;
  if (libsReady()) {
    const action = `video:plugin:${base}/plugins/slideshow.html`;
    return {
      name: 'A-INTERNAL-IMG',
      version: '1.0.0',
      type: 'list',
      headline: `Store Signage - ${ch.name} (crossfade)`,
      action,
      items: [{ title: 'Slideshow', playerLabel: 'Slideshow', action, properties: PLAYER_PROPS }],
    };
  }
  // MSX 라이브러리를 아직 못 받았으면 MSX 기본 플레이어로 영상을 하나씩 연다 (반복은 보장 안 됨, 이미지는 빠짐)
  const items = listJson(ch)
    .items.filter((it) => it.type === 'video')
    .map((it, k) => {
      const title = decodeURIComponent(path.basename(it.url));
      return { title, titleFooter: String(k + 1), playerLabel: title, action: `video:${origin}${it.url}`, properties: PLAYER_PROPS };
    });
  return {
    name: 'A-INTERNAL-IMG',
    version: '1.0.0',
    type: 'list',
    headline: items.length ? `Store Signage (${items.length} items)` : '영상이 없습니다: signage.mjs --sync 를 확인하세요',
    action: items.length ? items[0].action : null,
    template: { type: 'separate', layout: '0,0,8,1', color: 'msx-glass' },
    items,
  };
}

// ----- HTTP 서버 -----

function sendJson(req, res, status, obj) {
  const buf = Buffer.from(JSON.stringify(obj, null, 2));
  // TV 웹뷰 호환: chunked 대신 Content-Length 명시 (server.ps1 과 같음)
  res.writeHead(status, { ...CORS, 'Content-Type': TYPES['.json'], 'Content-Length': buf.length, 'Cache-Control': 'no-store' });
  res.end(req.method === 'HEAD' ? undefined : buf);
}

function safeJoin(root, rel) {
  const p = path.join(root, rel);
  return p.startsWith(root + path.sep) ? p : null;
}

async function serveFile(req, res, file, reqPath, remote, cache) {
  let st;
  try {
    st = await fsp.stat(file);
  } catch {
    return false;
  }
  if (!st.isFile()) return false;

  const total = st.size;
  let start = 0;
  let end = total - 1;
  let partial = false;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  if (m && (m[1] !== '' || m[2] !== '')) {
    if (m[1] === '') {
      start = Math.max(0, total - Number(m[2])); // bytes=-N : 끝에서 N 바이트
    } else {
      start = Number(m[1]);
      if (m[2] !== '') end = Math.min(Number(m[2]), total - 1);
    }
    if (start >= total || start > end) {
      res.writeHead(416, { ...CORS, 'Content-Range': `bytes */${total}`, 'Content-Length': 0 });
      res.end();
      log(`${req.method} ${reqPath} <- ${remote} -> 416 FILE ${path.basename(file)} (${req.headers.range})`);
      return true;
    }
    partial = true;
  }

  const headers = {
    ...CORS,
    'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream',
    'Content-Length': total === 0 ? 0 : end - start + 1,
    'Accept-Ranges': 'bytes',
    'Cache-Control': cache,
    'Last-Modified': st.mtime.toUTCString(),
  };
  if (partial) headers['Content-Range'] = `bytes ${start}-${end}/${total}`;
  const status = partial ? 206 : 200;
  res.writeHead(status, headers);
  if (req.method === 'HEAD' || total === 0) {
    res.end();
  } else {
    const stream = fs.createReadStream(file, { start, end });
    stream.on('error', () => res.destroy());
    res.on('close', () => stream.destroy()); // 영상 탐색 중 TV 가 끊는 건 정상
    stream.pipe(res);
  }
  log(`${req.method} ${reqPath} <- ${remote} -> ${status} FILE ${path.basename(file)} (${start}-${end}/${total})`);
  return true;
}

// /<채널>/media/<버전>/<파일> 만 내준다 (manifest.json, .tmp-* 같은 건 안 나감)
function mediaPath(ch, rel) {
  const parts = rel.split('/');
  if (parts.length !== 2) return null;
  const [ver, name] = parts;
  if (!(VERSION_RE.test(ver) || ver === 'current') || !isMedia(name) || name.startsWith('.')) return null;
  return safeJoin(ch.dir, `${ver}/${name}`);
}

async function handle(req, res) {
  const remote = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');
  // TV 가 접속한 주소로 모든 주소를 만든다. nginx(.221) 를 거치면 X-Forwarded-Proto 로 https 를 안다.
  const proto = req.headers['x-forwarded-proto'] === 'https' ? 'https' : 'http';
  const origin = `${proto}://${req.headers.host || `${lanIp()}:${PORT}`}`;
  let p;
  try {
    p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  } catch {
    p = '/';
  }

  if (req.method === 'OPTIONS') {
    res.writeHead(200, { ...CORS, 'Content-Length': 0 });
    res.end();
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendJson(req, res, 405, { error: 'method not allowed' });
    return;
  }

  // 첫 경로가 채널 이름이면 떼어 내고, 아니면 호스트 첫 이름(img.amartyyc.com -> img), 그것도 아니면 첫 채널
  // (/msx/start.json, /list.json 처럼 경로 없이 온 TV). start.json 이 /<채널>/ 주소를 내므로 그다음부터는 경로로 간다.
  const seg = p.split('/')[1] || '';
  const hostCh = CHANNEL_BY_NAME.get(String(req.headers.host || '').split('.')[0].toLowerCase());
  const ch = CHANNEL_BY_NAME.get(seg) || hostCh || CHANNELS[0];
  const rest = CHANNEL_BY_NAME.has(seg) ? p.slice(seg.length + 1) || '/' : p;
  const tag = `${req.method} ${p} <- ${remote} ->`;

  if (/start\.json$/.test(rest) || rest.startsWith('/msx')) {
    sendJson(req, res, 200, startJson(`${origin}/${ch.name}`));
    log(`${tag} START.JSON [${ch.name}]`);
  } else if (/list\.json$/.test(rest)) {
    sendJson(req, res, 200, listJson(ch));
    log(`${tag} LIST.JSON [${ch.name}]`);
  } else if (rest === '/' || /menu\.json$/.test(rest)) {
    sendJson(req, res, 200, menuJson(ch, origin));
    log(`${tag} MENU.JSON [${ch.name}]`);
  } else {
    let file = null;
    let cache = 'no-cache'; // 플러그인은 고칠 수 있으니 매번 확인
    if (rest.startsWith('/plugins/')) file = safeJoin(PLUGIN_DIR, rest.slice('/plugins/'.length));
    else if (rest.startsWith('/js/')) file = safeJoin(LIB_DIR, rest.slice('/js/'.length));
    else if (rest.startsWith('/media/')) {
      file = mediaPath(ch, rest.slice('/media/'.length));
      // 버전 폴더 주소는 내용이 안 바뀐다 -> TV 가 캐시해도 된다. current 는 아침마다 바뀌니 매번 확인.
      if (file && !rest.startsWith('/media/current/')) cache = 'public, max-age=604800, immutable';
    }
    if (file && (await serveFile(req, res, file, p, remote, cache))) return;
    // 모르는 경로는 메뉴로 (server.ps1 과 같음)
    sendJson(req, res, 200, menuJson(ch, origin));
    log(`${tag} MENU.JSON [${ch.name}] (fallback)`);
  }
}

function startServer() {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      log(`ERROR ${req.method} ${req.url}: ${e.stack || e.message}`);
      if (!res.headersSent) sendJson(req, res, 500, { error: 'internal error' });
      else res.destroy();
    });
  });
  server.listen(PORT, '0.0.0.0', () => {
    log(`A-INTERNAL-IMG (linux) 시작: DATA_DIR=${DATA_DIR}`);
    for (const ch of CHANNELS) {
      const ver = currentVersion(ch);
      const files = ver ? mediaFiles(path.join(ch.dir, ver)).join(', ') : '(없음: signage.mjs --sync 실행 필요)';
      log(`  채널 ${ch.name}: TV 의 MSX 에 ${lanIp()}:${PORT}/${ch.name}  버전=${ver || '-'}  파일=${files}`);
    }
  });
  if (!libsReady()) ensureLibs().catch(() => {});
}

// ----- 구글 드라이브 동기화 (--sync) -----

async function ensureLibs() {
  await fsp.mkdir(LIB_DIR, { recursive: true });
  for (const [url, name] of LIBS) {
    const dest = path.join(LIB_DIR, name);
    if (fs.existsSync(dest)) continue;
    try {
      const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(30000) });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const buf = Buffer.from(await r.arrayBuffer());
      if (buf.length === 0) throw new Error('빈 파일');
      await fsp.writeFile(`${dest}.part`, buf);
      await fsp.rename(`${dest}.part`, dest);
      log(`MSX 라이브러리 받음: ${name} (${buf.length} bytes)`);
    } catch (e) {
      log(`MSX 라이브러리 받기 실패: ${name} - ${e.message}`);
    }
  }
  return libsReady();
}

const errText = (e) => `${e.message}${e.cause ? ` (${e.cause.code || e.cause.message})` : ''}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 아침 6시 한 번의 순간 오류로 하루치 교체를 놓치지 않게 3번까지 (10초, 30초 쉬고) 다시 한다
async function retry(label, fn) {
  const waits = [10000, 30000];
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i >= waits.length) throw e;
      log(`${label} 실패, ${waits[i] / 1000}초 뒤 다시: ${errText(e)}`);
      await sleep(waits[i]);
    }
  }
}

const ENTITIES = { amp: '&', quot: '"', '#39': "'", lt: '<', gt: '>' };
const decodeEntities = (s) =>
  s.replace(/&(amp|quot|#39|lt|gt|#\d+);/g, (all, e) => ENTITIES[e] ?? String.fromCharCode(Number(e.slice(1))));

function stampNow() {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
}

// drive.usercontent 주소 + confirm=t 는 100MB 넘는 파일의 '바이러스 검사 못 함' 확인 페이지를 건너뛴다
async function download(id, dest) {
  const url = `https://drive.usercontent.google.com/download?id=${encodeURIComponent(id)}&export=download&confirm=t`;
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(30 * 60 * 1000) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  if ((r.headers.get('content-type') || '').startsWith('text/html')) throw new Error('파일 대신 HTML 이 왔음 (공유 설정 확인)');
  const hash = crypto.createHash('sha256');
  let size = 0;
  const count = new Transform({
    transform(chunk, _enc, cb) {
      hash.update(chunk);
      size += chunk.length;
      cb(null, chunk);
    },
  });
  await pipeline(Readable.fromWeb(r.body), count, fs.createWriteStream(dest));
  if (size === 0) throw new Error('0 바이트');
  return { size, sha256: hash.digest('hex') };
}

async function prune(ch, keep) {
  const versions = (await fsp.readdir(ch.dir)).filter((n) => VERSION_RE.test(n)).sort().reverse();
  for (const v of versions.slice(KEEP_VERSIONS)) {
    if (v === keep) continue;
    await fsp.rm(path.join(ch.dir, v), { recursive: true, force: true });
    log(`[${ch.name}] 오래된 버전 삭제: ${v}`);
  }
}

// 타이머와 손으로 돌린 --sync 가 겹치면 서로의 .tmp 를 지울 수 있어 한 번에 하나만 돈다
function takeLock(lock, again = true) {
  try {
    fs.writeFileSync(lock, String(process.pid), { flag: 'wx' });
    return true;
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
  }
  try {
    process.kill(Number(fs.readFileSync(lock, 'utf8')), 0);
    return false; // 살아 있는 동기화가 있다
  } catch (e) {
    if (e.code === 'EPERM') return false; // 다른 계정 프로세스지만 살아 있다
  }
  fs.rmSync(lock, { force: true }); // 죽은 프로세스가 남긴 잠금
  return again && takeLock(lock, false);
}

// 반환값 = 프로세스 종료 코드. 한 채널이라도 실패면 1 이라 systemctl status 에 failed 로 남는다. 실패한 채널도 지금 영상은 그대로.
async function sync(only) {
  const targets = only ? CHANNELS.filter((c) => c.name === only) : CHANNELS;
  if (targets.length === 0) {
    log(`없는 채널: ${only} (CHANNELS=${CHANNELS.map((c) => c.name).join(',')})`);
    return 1;
  }
  await fsp.mkdir(MEDIA_DIR, { recursive: true });
  const lock = path.join(DATA_DIR, '.sync.lock');
  if (!takeLock(lock)) {
    log('다른 동기화가 진행 중이라 건너뜀');
    return 0;
  }
  try {
    await ensureLibs();
    let code = 0;
    for (const ch of targets) code = Math.max(code, await syncChannel(ch));
    return code;
  } finally {
    fs.rmSync(lock, { force: true });
  }
}

async function syncChannel(ch) {
  const say = (msg) => log(`[${ch.name}] ${msg}`);
  if (!ch.folderId) {
    say('드라이브 폴더 ID 가 비어 있어 건너뜀');
    return 0;
  }
  await fsp.mkdir(ch.dir, { recursive: true });
  for (const n of await fsp.readdir(ch.dir)) {
    if (n.startsWith('.tmp-') || n.startsWith('.current-')) await fsp.rm(path.join(ch.dir, n), { recursive: true, force: true });
  }

  let html;
  try {
    html = await retry(`[${ch.name}] 드라이브 폴더 목록`, async () => {
      const r = await fetch(`https://drive.google.com/embeddedfolderview?id=${encodeURIComponent(ch.folderId)}`, {
        headers: UA,
        signal: AbortSignal.timeout(30000),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.text();
    });
  } catch (e) {
    say(`드라이브 폴더 목록 실패 -> 지금 영상 유지: ${errText(e)}`);
    return 1;
  }

  const files = [];
  const seen = new Set();
  for (const m of html.matchAll(/id="entry-([^"]+)"[\s\S]*?flip-entry-title">([^<]+)/g)) {
    let name = decodeEntities(m[2].trim()).replace(/[/\\\0]/g, '_');
    if (!isMedia(name)) continue;
    const ext = path.extname(name);
    if (seen.has(name.toLowerCase())) name = `${path.basename(name, ext)}_${m[1].slice(0, 6)}${ext}`;
    seen.add(name.toLowerCase());
    files.push({ id: m[1], name });
  }
  if (files.length === 0) {
    say('드라이브 폴더에 이미지·영상이 없음 -> 지금 영상 유지');
    return 1;
  }
  say(`드라이브 파일 ${files.length}개: ${files.map((f) => f.name).join(', ')}`);

  const tmp = path.join(ch.dir, `.tmp-${process.pid}`);
  await fsp.mkdir(tmp);
  const manifest = [];
  try {
    for (const f of files) {
      const info = await retry(`[${ch.name}] 다운로드 ${f.name}`, () => download(f.id, path.join(tmp, f.name)));
      manifest.push({ name: f.name, driveId: f.id, ...info });
      say(`  받음 ${f.name} (${info.size} bytes)`);
    }
  } catch (e) {
    say(`다운로드 실패 -> 적용 취소, 지금 영상 유지: ${errText(e)}`);
    await fsp.rm(tmp, { recursive: true, force: true });
    return 1;
  }

  // 받은 파일이 지금 것과 바이트까지 같으면 버전을 바꾸지 않는다 (TV 가 괜히 다시 받지 않게)
  const sig = (list) => list.map((x) => `${x.name}\t${x.sha256}`).sort().join('\n');
  const cur = currentVersion(ch);
  if (cur) {
    try {
      const old = JSON.parse(await fsp.readFile(path.join(ch.dir, cur, 'manifest.json'), 'utf8'));
      if (sig(old) === sig(manifest)) {
        say(`변경 없음: ${cur} 그대로`);
        await fsp.rm(tmp, { recursive: true, force: true });
        return 0;
      }
    } catch {}
  }

  await fsp.writeFile(path.join(tmp, 'manifest.json'), JSON.stringify(manifest, null, 2));
  let stamp = stampNow();
  while (fs.existsSync(path.join(ch.dir, stamp))) {
    await sleep(1000); // 같은 초에 두 번 적용하면 버전 이름이 겹친다
    stamp = stampNow();
  }
  await fsp.rename(tmp, path.join(ch.dir, stamp));
  const link = path.join(ch.dir, `.current-${stamp}`);
  await fsp.symlink(stamp, link);
  await fsp.rename(link, path.join(ch.dir, 'current')); // 심볼릭 링크를 원자적으로 바꾼다
  say(`적용: ${stamp} (${manifest.map((x) => x.name).join(', ')})`);
  await prune(ch, stamp);
  return 0;
}

const syncAt = process.argv.indexOf('--sync');
if (syncAt >= 0) {
  process.exitCode = await sync(process.argv[syncAt + 1]);
} else {
  startServer();
}
