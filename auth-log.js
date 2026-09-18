/**
 * Login auditing: append every login attempt to a JSONL file on the runs volume,
 * geolocate the client IP, and mail a once-a-day digest.
 *
 * Everything here fails soft. A lookup timeout, a missing API key or an
 * unwritable log must never stop somebody signing in, so every path is wrapped
 * and errors go to the console rather than to the caller.
 */

const fs   = require('fs');
const path = require('path');

const LOG_FILE   = 'auth-log.jsonl';
const STATE_FILE = 'auth-log-state.json';

// ip-api.com's free tier is HTTP-only and allows ~45 lookups/minute. Results are
// cached per IP for the life of the process, so a returning user costs nothing.
const GEO_URL = ip =>
  `http://ip-api.com/json/${encodeURIComponent(ip)}?fields=status,country,regionName,city,isp`;
const GEO_TIMEOUT_MS = 4000;

const PRIVATE_IP = /^(::1|::ffff:127\.|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|fc|fd)/i;

function createAuthLog({
  runsDir,
  emailTo,
  resendKey,
  emailFrom  = 'onboarding@resend.dev',
  digestHour = 8,
  geolocate  = true,
} = {}) {
  const logPath   = path.join(runsDir, LOG_FILE);
  const statePath = path.join(runsDir, STATE_FILE);
  const geoCache  = new Map();

  // ── geolocation ───────────────────────────────────────────────────────────
  async function lookup(ip) {
    if (!geolocate || !ip || PRIVATE_IP.test(ip)) return null;
    if (geoCache.has(ip)) return geoCache.get(ip);

    let geo = null;
    try {
      const res = await fetch(GEO_URL(ip), { signal: AbortSignal.timeout(GEO_TIMEOUT_MS) });
      const body = await res.json();
      if (body && body.status === 'success') {
        geo = { city: body.city || null, region: body.regionName || null,
                country: body.country || null, isp: body.isp || null };
      }
    } catch (err) {
      console.warn(`Geolocation failed for ${ip}: ${err.message}`);
    }
    geoCache.set(ip, geo);
    return geo;
  }

  // ── writing ───────────────────────────────────────────────────────────────
  function append(entry) {
    try {
      fs.appendFileSync(logPath, JSON.stringify(entry) + '\n');
    } catch (err) {
      console.warn(`Could not write ${logPath}: ${err.message}`);
    }
  }

  /**
   * Record one login attempt. Returns immediately; the geolocation lookup and
   * the write happen in the background so the sign-in response is never delayed.
   */
  function record({ outcome, ip, user, userAgent }) {
    const entry = {
      ts: new Date().toISOString(),
      outcome,                                  // 'success' | 'failure'
      ip: ip || null,
      user: user || null,
      userAgent: (userAgent || '').slice(0, 300) || null,
    };

    lookup(entry.ip)
      .then(geo => append(geo ? { ...entry, ...geo } : entry))
      .catch(() => append(entry));
  }

  // ── digest ────────────────────────────────────────────────────────────────
  function readEntriesForDay(dayISO) {
    if (!fs.existsSync(logPath)) return [];
    return fs.readFileSync(logPath, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map(line => { try { return JSON.parse(line); } catch { return null; } })
      .filter(e => e && typeof e.ts === 'string' && e.ts.startsWith(dayISO));
  }

  function buildDigest(dayISO, entries) {
    const ok   = entries.filter(e => e.outcome === 'success');
    const bad  = entries.filter(e => e.outcome === 'failure');
    const byIp = new Map();

    for (const e of entries) {
      const key = e.ip || 'unknown';
      const row = byIp.get(key) || {
        ip: key, successes: 0, failures: 0, first: e.ts, last: e.ts,
        where: [e.city, e.region, e.country].filter(Boolean).join(', ') || 'unknown',
        isp: e.isp || null,
      };
      if (e.outcome === 'success') row.successes++; else row.failures++;
      if (e.ts < row.first) row.first = e.ts;
      if (e.ts > row.last)  row.last  = e.ts;
      byIp.set(key, row);
    }

    const lines = [
      `B-ALL Ensemble Classifier — login digest for ${dayISO}`,
      '',
      `Successful logins: ${ok.length}`,
      `Failed attempts:   ${bad.length}`,
      `Distinct IPs:      ${byIp.size}`,
      '',
    ];

    if (byIp.size === 0) {
      lines.push('No login activity.');
    } else {
      lines.push('By address:', '');
      for (const r of [...byIp.values()].sort((a, b) => b.successes - a.successes)) {
        lines.push(`  ${r.ip}  (${r.where})`);
        lines.push(`    ${r.successes} ok, ${r.failures} failed` +
                   `   ${r.first.slice(11, 16)}–${r.last.slice(11, 16)} UTC` +
                   (r.isp ? `   ${r.isp}` : ''));
      }
    }

    if (bad.length >= 10) {
      lines.push('', `NOTE: ${bad.length} failed attempts — someone may be guessing the password.`);
    }

    return { subject: `B-ALL classifier logins — ${dayISO} (${ok.length} in, ${bad.length} failed)`,
             text: lines.join('\n') };
  }

  async function sendEmail({ subject, text }) {
    if (!resendKey || !emailTo) {
      console.warn('Login digest not sent: RESEND_API_KEY or ALERT_EMAIL_TO is unset.');
      return false;
    }
    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: emailFrom, to: [emailTo], subject, text }),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        console.warn(`Login digest rejected (${res.status}): ${(await res.text()).slice(0, 300)}`);
        return false;
      }
      console.log(`Login digest sent to ${emailTo}.`);
      return true;
    } catch (err) {
      console.warn(`Login digest failed to send: ${err.message}`);
      return false;
    }
  }

  const readState = () => {
    try { return JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { return {}; }
  };
  const writeState = state => {
    try { fs.writeFileSync(statePath, JSON.stringify(state, null, 2)); }
    catch (err) { console.warn(`Could not write ${statePath}: ${err.message}`); }
  };

  const dayBefore = date => new Date(date.getTime() - 86400000).toISOString().slice(0, 10);

  /**
   * Once an hour, check whether yesterday's digest still needs sending. Keeping
   * the last sent day on disk means a restart or a missed hour doesn't skip it.
   */
  async function maybeSendDigest() {
    if (!resendKey || !emailTo) return;

    const now = new Date();
    if (now.getUTCHours() < digestHour) return;

    const target = dayBefore(now);
    const state  = readState();
    if (state.lastDigestDay === target) return;

    const { subject, text } = buildDigest(target, readEntriesForDay(target));
    if (await sendEmail({ subject, text })) {
      writeState({ ...state, lastDigestDay: target });
    }
  }

  function start() {
    if (!resendKey || !emailTo) {
      console.log('   Digest:  disabled (set RESEND_API_KEY and ALERT_EMAIL_TO to enable)');
      return;
    }
    console.log(`   Digest:  daily to ${emailTo} at ${String(digestHour).padStart(2, '0')}:00 UTC`);
    maybeSendDigest();
    const timer = setInterval(maybeSendDigest, 60 * 60 * 1000);
    timer.unref();
  }

  return { record, start, buildDigest, readEntriesForDay, logPath };
}

module.exports = { createAuthLog };
