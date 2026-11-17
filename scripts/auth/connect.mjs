#!/usr/bin/env node
// Authorizes the CLI from a browser session, for clients who only give us
// Subscriber Access or a single/one-time login URL (no credentials, no user).
//
// Opens a dedicated Chrome profile and waits for you to log in there. Then:
//   1. It reads the API session cookie (sid) from the browser itself, so no DevTools copying.
//   2. It tries to upgrade to a real OAuth login (refresh token) in the same browser. That
//      login outlives the browser session. Login-as / Subscriber Access sessions can't
//      approve OAuth, so press Enter to skip when the page shows an error.
//   3. Otherwise it saves the sid. That auth lives only as long as the browser session.
//      Re-run with --refresh "<alias>" to pick up a new session for the same org.
//
// Usage:
//   node scripts/auth/connect.mjs [loginUrl] [-a "<Customer> - Production"] [--no-oauth] [--keepalive]
//   node scripts/auth/connect.mjs --refresh "<alias>" [--keepalive]
//
//   loginUrl     single login URL / frontdoor link / https://<mydomain>.my.salesforce.com.
//                Leave out for Subscriber Access: log in to the partner org in the opened
//                browser and click Login on the subscriber; the new session is detected.
//   --keepalive  keep running and call the API every 10 minutes so a sid auth doesn't idle out.
//
// The browser profile lives in ~/.sf-auth-browser (outside OneDrive, since it holds live sessions).

import { spawn, execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { realpathSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PROFILE_DIR = join(homedir(), '.sf-auth-browser');
const DEBUG_PORT = 9333;
const SF_COOKIE_DOMAIN = /(^|\.)my\.salesforce\.com$/;
const LOGIN_WAIT_MS = 15 * 60_000;
const OAUTH_WAIT_MS = 120_000;
const KEEPALIVE_MS = 10 * 60_000;

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const API_VERSION = JSON.parse(readFileSync(join(PROJECT_ROOT, 'sfdx-project.json'), 'utf8')).sourceApiVersion;

// Use the CLI's own @salesforce/core so auth files are encrypted and stored exactly like `sf org login`.
const sfRoot = dirname(dirname(realpathSync(execSync('command -v sf', { encoding: 'utf8' }).trim())));
const { AuthInfo, StateAggregator, WebOAuthServer } = createRequire(join(sfRoot, 'package.json'))('@salesforce/core');

// ---------- args ----------
const args = process.argv.slice(2);
const opts = { url: '', alias: '', refresh: '', oauth: true, keepalive: false };
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-a' || a === '--alias') opts.alias = args[++i] ?? '';
    else if (a === '--refresh') opts.refresh = args[++i] ?? '';
    else if (a === '--no-oauth') opts.oauth = false;
    else if (a === '--keepalive') opts.keepalive = true;
    else if (a === '-h' || a === '--help') usage();
    else if (!opts.url && /^https:\/\//.test(a)) opts.url = a;
    else usage(`Unknown argument: ${a}`);
}
function usage(msg) {
    if (msg) console.error(msg);
    const src = readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n');
    console.error(src.slice(1, 22).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    process.exit(1);
}

// ---------- small helpers ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(m);
const fail = (m) => { console.error(m); process.exit(1); };

function ask(question) {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((r) => rl.question(question, (ans) => { rl.close(); r(ans.trim()); }));
}

// Resolves when the user presses Enter; the returned cancel() stops listening.
function waitForEnter() {
    const rl = createInterface({ input: process.stdin });
    let cancel;
    const p = new Promise((r) => { rl.once('line', () => r('enter')); cancel = () => rl.close(); });
    return { promise: p, cancel };
}

// ---------- Chrome over the DevTools protocol ----------
async function devtoolsVersion() {
    try {
        const res = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/version`);
        return res.ok ? await res.json() : null;
    } catch {
        return null;
    }
}

async function ensureChrome() {
    if (await devtoolsVersion()) return;
    // Chrome only honours --remote-debugging-port with a non-default profile, hence PROFILE_DIR.
    spawn(CHROME, [`--user-data-dir=${PROFILE_DIR}`, `--remote-debugging-port=${DEBUG_PORT}`,
        '--no-first-run', '--no-default-browser-check', 'about:blank'], { detached: true, stdio: 'ignore' }).unref();
    for (let i = 0; i < 50; i++) {
        if (await devtoolsVersion()) return;
        await sleep(300);
    }
    fail('Chrome did not start with remote debugging. Close any Chrome window using ~/.sf-auth-browser and retry.');
}

async function browser() {
    const { webSocketDebuggerUrl } = await devtoolsVersion();
    const ws = new WebSocket(webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    let seq = 0;
    const pending = new Map();
    ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        const p = pending.get(msg.id);
        if (!p) return;
        pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
    };
    return {
        send: (method, params = {}) => new Promise((resolve, reject) => {
            const id = ++seq;
            pending.set(id, { resolve, reject });
            ws.send(JSON.stringify({ id, method, params }));
        }),
        close: () => ws.close(),
    };
}

async function openTab(b, url) {
    await b.send('Target.createTarget', { url });
}

// Only the my.salesforce.com sid is API-enabled; lightning.force.com / file.force.com sids are UI-only.
async function salesforceSids(b) {
    const { cookies } = await b.send('Storage.getCookies');
    return cookies
        .filter((c) => c.name === 'sid' && SF_COOKIE_DOMAIN.test(c.domain.replace(/^\./, '')))
        .map((c) => ({ sid: c.value, host: c.domain.replace(/^\./, '') }));
}

// ---------- Salesforce ----------
// SOAP getUserInfo works for sessions whose /services/oauth2/userinfo redirects to logout.jsp
// (seen with subscriber sessions), which is why `sf org login access-token` can fail on them.
async function whoAmI(instanceUrl, sid) {
    const esc = sid.replace(/&/g, '&amp;').replace(/</g, '&lt;');
    const body = `<?xml version="1.0" encoding="utf-8"?><env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:partner.soap.sforce.com"><env:Header><urn:SessionHeader><urn:sessionId>${esc}</urn:sessionId></urn:SessionHeader></env:Header><env:Body><urn:getUserInfo/></env:Body></env:Envelope>`;
    try {
        const res = await fetch(`${instanceUrl}/services/Soap/u/${API_VERSION}`, {
            method: 'POST', headers: { 'Content-Type': 'text/xml', SOAPAction: '""' }, body, redirect: 'manual',
        });
        if (!res.ok) return null;
        const xml = await res.text();
        const tag = (t) => xml.match(new RegExp(`<${t}>([^<]*)</${t}>`))?.[1] ?? '';
        const info = { username: tag('userName'), orgId: tag('organizationId'), orgName: tag('organizationName') };
        if (!info.username || !info.orgId) return null;
        const q = await fetch(`${instanceUrl}/services/data/v${API_VERSION}/query?q=${encodeURIComponent('SELECT IsSandbox FROM Organization')}`,
            { headers: { Authorization: `Bearer ${sid}` } });
        info.isSandbox = q.ok ? (await q.json()).records?.[0]?.IsSandbox === true : /\.sandbox\./.test(instanceUrl);
        return info;
    } catch {
        return null;
    }
}

async function existingAuthForOrg(orgId) {
    const sa = await StateAggregator.getInstance();
    const auths = await AuthInfo.listAllAuthorizations();
    const hit = auths.find((a) => a.orgId?.slice(0, 15) === orgId.slice(0, 15));
    if (!hit) return null;
    return { username: hit.username, alias: hit.aliases?.[0] ?? sa.aliases.get(hit.username) ?? '', instanceUrl: hit.instanceUrl };
}

async function authForAlias(alias) {
    const sa = await StateAggregator.getInstance();
    const username = sa.aliases.resolveUsername(alias);
    const auths = await AuthInfo.listAllAuthorizations();
    return auths.find((a) => a.username === username) ?? null;
}

async function setAlias(alias, username) {
    const sa = await StateAggregator.getInstance();
    await sa.aliases.setAndSave(alias, username);
}

async function saveSidAuth(instanceUrl, sid, info) {
    const sa = await StateAggregator.getInstance();
    sa.orgs.set(info.username, {
        username: info.username, accessToken: sid, instanceUrl, loginUrl: instanceUrl,
        orgId: info.orgId, isDevHub: false, isSandbox: info.isSandbox,
    });
    await sa.orgs.write(info.username);
}

// Runs the CLI's normal web OAuth flow, but in our Chrome profile where the client session lives.
async function tryOAuth(b, instanceUrl) {
    let server;
    try {
        server = await WebOAuthServer.create({ oauthConfig: { loginUrl: instanceUrl } });
        await server.start();
    } catch (e) {
        log(`  Couldn't start the OAuth callback server (${e.message}). Skipping OAuth.`);
        return null;
    }
    await openTab(b, server.getAuthorizationUrl());
    log('  Opened the OAuth "Allow" page in the browser.');
    log('  Click Allow. If it shows an error (normal for login-as / Subscriber Access), press Enter to skip.');
    const enter = waitForEnter();
    const result = await Promise.race([
        server.authorizeAndSave().then((ai) => ai, () => null),
        enter.promise.then(() => null),
        sleep(OAUTH_WAIT_MS).then(() => null),
    ]);
    enter.cancel();
    return result;
}

// ---------- main ----------
async function pickSession(b, baseline) {
    const wantHost = opts.url ? new URL(opts.url).host : '';
    const deadline = Date.now() + LOGIN_WAIT_MS;
    const rejected = new Set();
    let announced = false;
    while (Date.now() < deadline) {
        const sids = await salesforceSids(b);
        // New sessions, or any session on the host we were sent to.
        const candidates = sids.filter((s) => !rejected.has(s.sid)
            && (!baseline.has(s.sid) || (wantHost && s.host === wantHost)));
        for (const c of candidates) {
            const instanceUrl = `https://${c.host}`;
            const info = await whoAmI(instanceUrl, c.sid);
            if (!info) { rejected.add(c.sid); continue; }
            const answer = await ask(`Found session: ${info.username} @ ${info.orgName} (${info.orgId}, ${info.isSandbox ? 'sandbox' : 'production'}). Use it? [Y/n] `);
            if (/^n/i.test(answer)) { rejected.add(c.sid); continue; }
            return { instanceUrl, sid: c.sid, info };
        }
        if (!announced) { log('Waiting for you to log in to the client org in the opened browser...'); announced = true; }
        await sleep(2000);
    }
    fail('Timed out waiting for a Salesforce session.');
}

async function keepAlive(alias, instanceUrl, token) {
    log(`Keeping the session alive (API call every ${KEEPALIVE_MS / 60_000} min). Ctrl-C to stop.`);
    for (;;) {
        await sleep(KEEPALIVE_MS);
        const res = await fetch(`${instanceUrl}/services/data/v${API_VERSION}/limits`, { headers: { Authorization: `Bearer ${token}` } }).catch(() => null);
        const t = new Date().toLocaleTimeString();
        if (res?.ok) log(`  ${t} session alive`);
        else fail(`  ${t} session expired (HTTP ${res?.status ?? 'error'}). Log in again and run --refresh "${alias}".`);
    }
}

async function main() {
    await ensureChrome();
    const b = await browser();

    let refreshTarget = null;
    if (opts.refresh) {
        refreshTarget = await authForAlias(opts.refresh);
        if (!refreshTarget) fail(`No authorized org with alias "${opts.refresh}". Run without --refresh first.`);
        opts.alias = opts.refresh;
        opts.url ||= refreshTarget.instanceUrl;
    }

    const baseline = new Set((await salesforceSids(b)).map((s) => s.sid));
    if (opts.url) {
        const host = new URL(opts.url).host;
        // Reuse a still-valid session for that host instead of opening a new login.
        const live = (await salesforceSids(b)).find((s) => s.host === host);
        if (!live || !(await whoAmI(`https://${host}`, live.sid))) await openTab(b, opts.url);
    } else {
        log('No login URL given: log in to the client org in the opened browser (e.g. via Subscriber Access).');
    }

    const { instanceUrl, sid, info } = await pickSession(b, baseline);
    if (refreshTarget && refreshTarget.orgId?.slice(0, 15) !== info.orgId.slice(0, 15)) {
        fail(`That session is for org ${info.orgId}, but "${opts.refresh}" is org ${refreshTarget.orgId}. Nothing saved.`);
    }

    const existing = await existingAuthForOrg(info.orgId);
    let alias = opts.alias || existing?.alias;
    if (!alias) {
        const suggested = `${info.orgName} - ${info.isSandbox ? 'Sandbox' : 'Production'}`;
        alias = (await ask(`Alias for this org [${suggested}]: `)) || suggested;
    }

    let mode = 'sid';
    if (opts.oauth && !opts.refresh) {
        const authInfo = await tryOAuth(b, instanceUrl);
        if (authInfo) {
            await setAlias(alias, authInfo.getUsername());
            mode = 'oauth';
            log(`OAuth login saved for ${authInfo.getUsername()} (refresh token; doesn't depend on the browser session).`);
        } else {
            log('  OAuth not available for this session; saving the browser session instead.');
        }
    }
    if (mode === 'sid') {
        await saveSidAuth(instanceUrl, sid, info);
        await setAlias(alias, info.username);
        log(`Session saved for ${info.username}. It works until the browser session ends or times out.`);
        log(`When it expires: log in again in the same browser, then run: node scripts/auth/connect.mjs --refresh "${alias}"`);
    }
    b.close();

    try {
        const out = execSync(`sf data query -o "${alias}" -q "SELECT Name FROM Organization" --json`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
        log(`Verified: "${alias}" -> ${JSON.parse(out).result.records[0].Name}`);
    } catch {
        fail(`Saved "${alias}", but the test query failed. Check with: sf org display -o "${alias}"`);
    }
    const mapped = Object.values(JSON.parse(readFileSync(join(PROJECT_ROOT, 'customers', 'customers.json'), 'utf8'))).includes(alias);
    if (!mapped) log('Not in customers/customers.json yet. Org Guard (VS Code) registers it automatically, or add it by hand.');

    if (opts.keepalive && mode === 'sid') await keepAlive(alias, instanceUrl, sid);
    process.exit(0);
}

main().catch((e) => fail(e.stack ?? String(e)));
