// Parkour data module (SpacetimeDB 2.x, TypeScript).
//
// The Python API (agent/) is the only client. It connects with the database owner's token, so every
// table is private (default) and every reducer refuses anyone but the owner. Password hashing and
// session tokens are made by the API; this module stores the hash, never a password.
import { schema, table, t, SenderError } from 'spacetimedb/server';

// ---------- tables ----------
const owner = table({ name: 'owner' }, {
  id: t.u8().primaryKey(),
  identity: t.identity(),
});

// One row per person (anonymous device or signed-up account).
const profile = table({ name: 'profile' }, {
  user_id: t.string().primaryKey(),
  name: t.string(),
  phone: t.string().index('btree'),
  email: t.string(),
  consent_register: t.bool(),
  spending_cap_usd: t.f64(),
  notify_channel: t.string(),
  created_at: t.string(),
  updated_at: t.string(),
});

// Sign-in details. Only people who signed up have one.
const credential = table({ name: 'credential' }, {
  user_id: t.string().primaryKey(),
  email: t.string().unique(),          // lower-cased
  password_hash: t.string(),           // scrypt$n$r$p$salt$hash, made by the API
  created_at: t.string(),
});

// Only the SHA-256 of the session token is stored.
const session = table({ name: 'session' }, {
  token_hash: t.string().primaryKey(),
  user_id: t.string().index('btree'),
  created_at: t.string(),
  expires_at: t.string(),
});

const vehicle = table({ name: 'vehicle' }, {
  vehicle_id: t.string().primaryKey(),
  user_id: t.string().index('btree'),
  plate: t.string(),
  state: t.string(),
  make: t.string(),
  model: t.string(),
  color: t.string(),
  year: t.u32(),                       // 0 = unknown
  created_at: t.string(),
});

// "Past parking info": where this person has parked before and what they entered, so the app can prefill it.
const saved_place = table({ name: 'saved_place' }, {
  place_id: t.string().primaryKey(),   // hash of user + property + unit + host, made by the API
  user_id: t.string().index('btree'),
  property_id: t.string(),
  property_name: t.string(),
  unit: t.string(),
  host_name: t.string(),
  vehicle_id: t.string(),
  plate: t.string(),
  duration_hours: t.u32(),
  label: t.string(),                   // optional nickname
  uses: t.u32(),
  first_used_at: t.string(),
  last_used_at: t.string(),
});

// One row per registration attempt, updated as its status changes.
const parking_history = table({ name: 'parking_history' }, {
  registration_id: t.string().primaryKey(),
  user_id: t.string().index('btree'),
  property_id: t.string(),
  property_name: t.string(),
  plate: t.string(),
  unit: t.string(),
  status: t.string(),
  confirmation_number: t.string(),
  expires_at: t.string(),
  created_at: t.string(),
  updated_at: t.string(),
});

// Seeded complexes. Only the fields the rules need; distance and map data stay in the API.
const property = table({ name: 'property' }, {
  property_id: t.string().primaryKey(),
  name: t.string(),
  campus: t.string(),
  lat: t.f64(),
  lng: t.f64(),
  vendor_id: t.string(),               // '' = permit-only or gated
  property_code: t.string(),
  portal_path: t.string(),
  max_nights_per_month: t.u32(),
  max_duration_hours: t.u32(),
  requires_host_unit: t.bool(),
  notes: t.string(),
});

// The registration state machine. Nested objects are stored as JSON text.
const registration = table({ name: 'registration' }, {
  registration_id: t.string().primaryKey(),
  user_id: t.string().index('btree'),
  status: t.string().index('btree'),
  flow: t.string(),                    // 'standard' | 'maverick'
  property_id: t.string(),
  property_name: t.string(),
  vehicle_id: t.string(),
  plate: t.string(),
  state: t.string(),
  make: t.string(),
  model: t.string(),
  color: t.string(),
  role: t.string(),
  host_name: t.string(),
  host_unit: t.string(),
  duration_hours: t.u32(),
  summary: t.string(),
  alternatives_json: t.string(),
  steps_json: t.string(),
  needs_user_json: t.string(),         // '' when none
  proof_json: t.string(),
  error_json: t.string(),
  answers_json: t.string(),            // answers given to Check 2 questions
  guest_json: t.string(),              // Maverick Place guest details
  override: t.bool(),
  captcha_cleared: t.bool(),
  dry_run: t.bool(),
  reminded: t.bool(),
  run_state: t.string(),               // '' = waiting for a worker, 'running' = a worker has it
  confirmed_via: t.string(),
  created_at: t.string(),
  created_at_ms: t.string(),           // same moment, millisecond precision: orders attempts made in one second
  updated_at: t.string(),
});

// Switches on the test-only wipe reducer. Never set in a real deployment.
const config = table({ name: 'config' }, { key: t.string().primaryKey(), value: t.string() });

const spacetimedb = schema({ owner, profile, credential, session, vehicle, saved_place, parking_history, property, registration, config });
export default spacetimedb;

// ---------- guard ----------
function requireOwner(ctx: any) {
  const row = ctx.db.owner.id.find(1);
  if (!row || !ctx.sender.isEqual(row.identity)) {
    throw new SenderError('not allowed');
  }
}

export const init = spacetimedb.init((ctx) => {
  // The publisher becomes the only caller the reducers accept.
  if (!ctx.db.owner.id.find(1)) {
    ctx.db.owner.insert({ id: 1, identity: ctx.sender });
  }
});

// Fallback if init ran without a usable sender: the first caller claims ownership once.
export const claim_owner = spacetimedb.reducer((ctx) => {
  if (!ctx.db.owner.id.find(1)) {
    ctx.db.owner.insert({ id: 1, identity: ctx.sender });
    return;
  }
  requireOwner(ctx);
});

// ---------- profiles and accounts ----------
export const upsert_profile = spacetimedb.reducer({
  user_id: t.string(), name: t.string(), phone: t.string(), email: t.string(),
  consent_register: t.bool(), spending_cap_usd: t.f64(), notify_channel: t.string(), now: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const old = ctx.db.profile.user_id.find(a.user_id);
  const row = {
    user_id: a.user_id, name: a.name, phone: a.phone, email: a.email,
    consent_register: a.consent_register, spending_cap_usd: a.spending_cap_usd,
    notify_channel: a.notify_channel, created_at: old ? old.created_at : a.now, updated_at: a.now,
  };
  if (old) ctx.db.profile.user_id.update(row); else ctx.db.profile.insert(row);
});

export const create_credential = spacetimedb.reducer({
  user_id: t.string(), email: t.string(), password_hash: t.string(), now: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  if (ctx.db.credential.email.find(a.email)) throw new SenderError('email_taken');
  if (ctx.db.credential.user_id.find(a.user_id)) throw new SenderError('user_has_account');
  ctx.db.credential.insert({ user_id: a.user_id, email: a.email, password_hash: a.password_hash, created_at: a.now });
});

export const set_password = spacetimedb.reducer({ user_id: t.string(), password_hash: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const c = ctx.db.credential.user_id.find(a.user_id);
  if (!c) throw new SenderError('no_account');
  ctx.db.credential.user_id.update({ ...c, password_hash: a.password_hash });
});

// ---------- sessions ----------
export const create_session = spacetimedb.reducer({
  token_hash: t.string(), user_id: t.string(), now: t.string(), expires_at: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  ctx.db.session.insert({ token_hash: a.token_hash, user_id: a.user_id, created_at: a.now, expires_at: a.expires_at });
});

export const delete_session = spacetimedb.reducer({ token_hash: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  ctx.db.session.token_hash.delete(a.token_hash);
});

export const delete_user_sessions = spacetimedb.reducer({ user_id: t.string(), keep_token_hash: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  for (const s of [...ctx.db.session.user_id.filter(a.user_id)]) {
    if (s.token_hash !== a.keep_token_hash) ctx.db.session.token_hash.delete(s.token_hash);
  }
});

// ISO-8601 UTC strings sort the same as the times they describe.
export const purge_expired_sessions = spacetimedb.reducer({ now: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  for (const s of [...ctx.db.session.iter()]) {
    if (s.expires_at < a.now) ctx.db.session.token_hash.delete(s.token_hash);
  }
});

// ---------- vehicles ----------
export const upsert_vehicle = spacetimedb.reducer({
  vehicle_id: t.string(), user_id: t.string(), plate: t.string(), state: t.string(), make: t.string(),
  model: t.string(), color: t.string(), year: t.u32(), now: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const old = ctx.db.vehicle.vehicle_id.find(a.vehicle_id);
  if (old && old.user_id !== a.user_id) throw new SenderError('not_yours');
  const row = {
    vehicle_id: a.vehicle_id, user_id: a.user_id, plate: a.plate, state: a.state, make: a.make,
    model: a.model, color: a.color, year: a.year, created_at: old ? old.created_at : a.now,
  };
  if (old) ctx.db.vehicle.vehicle_id.update(row); else ctx.db.vehicle.insert(row);
});

export const delete_vehicle = spacetimedb.reducer({ user_id: t.string(), vehicle_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const v = ctx.db.vehicle.vehicle_id.find(a.vehicle_id);
  if (v && v.user_id === a.user_id) ctx.db.vehicle.vehicle_id.delete(a.vehicle_id);
});

// ---------- saved places (past parking info) ----------
export const label_place = spacetimedb.reducer({ user_id: t.string(), place_id: t.string(), label: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const p = ctx.db.saved_place.place_id.find(a.place_id);
  if (!p || p.user_id !== a.user_id) throw new SenderError('not_found');
  ctx.db.saved_place.place_id.update({ ...p, label: a.label });
});

export const forget_place = spacetimedb.reducer({ user_id: t.string(), place_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const p = ctx.db.saved_place.place_id.find(a.place_id);
  if (p && p.user_id === a.user_id) ctx.db.saved_place.place_id.delete(a.place_id);
});

// ---------- delete account ----------
export const delete_user = spacetimedb.reducer({ user_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  for (const s of [...ctx.db.session.user_id.filter(a.user_id)]) ctx.db.session.token_hash.delete(s.token_hash);
  for (const v of [...ctx.db.vehicle.user_id.filter(a.user_id)]) ctx.db.vehicle.vehicle_id.delete(v.vehicle_id);
  for (const p of [...ctx.db.saved_place.user_id.filter(a.user_id)]) ctx.db.saved_place.place_id.delete(p.place_id);
  for (const h of [...ctx.db.parking_history.user_id.filter(a.user_id)]) ctx.db.parking_history.registration_id.delete(h.registration_id);
  for (const r of [...ctx.db.registration.user_id.filter(a.user_id)]) ctx.db.registration.registration_id.delete(r.registration_id);
  ctx.db.credential.user_id.delete(a.user_id);
  ctx.db.profile.user_id.delete(a.user_id);
});


// =====================================================================================
// Registrations (phase 1): drafting, rules, the state machine and the worker hand-off.
// Errors are thrown as "code: message" so the API can turn them into the contract's error bodies.
// =====================================================================================
const COUNTED = ['submitting', 'needs_user', 'confirmed', 'expired', 'finished'];
const SKIP_HISTORY = ['drafted', 'awaiting_confirm'];

function fail(code: string, message: string): never {
  throw new SenderError(`${code}: ${message}`);
}

function iso(ctx: any): string {                       // seconds precision, as the contract writes timestamps
  return ctx.timestamp.toISOString().replace(/\.\d+Z$/, 'Z');
}
function isoMs(ctx: any): string {                     // millisecond precision, for ordering rows made in one second
  return ctx.timestamp.toISOString();
}

// ----- US Central time (the properties are all in Texas) -----
function nthSunday(year: number, month: number, n: number): number {
  const first = new Date(Date.UTC(year, month, 1)).getUTCDay();
  return 1 + ((7 - first) % 7) + 7 * (n - 1);
}
function centralOffsetHours(d: Date): number {
  const y = d.getUTCFullYear();
  const start = Date.UTC(y, 2, nthSunday(y, 2, 2), 8, 0);   // 2nd Sunday of March, 2:00 CST
  const end = Date.UTC(y, 10, nthSunday(y, 10, 1), 7, 0);   // 1st Sunday of November, 2:00 CDT
  return d.getTime() >= start && d.getTime() < end ? -5 : -6;
}
function central(d: Date): Date {                      // a Date whose UTC fields read as Central wall-clock time
  return new Date(d.getTime() + centralOffsetHours(d) * 3600_000);
}
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
function untilText(now: Date, hours: number): string {
  const until = central(new Date(now.getTime() + hours * 3600_000));
  const here = central(now);
  const h = until.getUTCHours();
  const t12 = `${h % 12 === 0 ? 12 : h % 12}:${String(until.getUTCMinutes()).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
  const sameDay = until.getUTCFullYear() === here.getUTCFullYear() && until.getUTCMonth() === here.getUTCMonth()
    && until.getUTCDate() === here.getUTCDate();
  return sameDay ? t12 : `${t12} on ${DAYS[until.getUTCDay()]}`;
}

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = 6371000, rad = (x: number) => (x * Math.PI) / 180;
  const dp = rad(lat2 - lat1), dl = rad(lng2 - lng1);
  const a = Math.sin(dp / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dl / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}

// 106-bit string hash (two cyrb53 passes): stable ids for saved places without a crypto library.
function cyrb53(str: string, seed: number): string {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16).padStart(14, '0');
}
const alnum = (s: string) => (s || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
function placeId(userId: string, propertyId: string, unit: string, host: string): string {
  const key = [userId, propertyId, alnum(unit), alnum(host)].join('|');
  return 'pl_' + cyrb53(key, 1) + cyrb53(key, 2).slice(0, 6);
}

// ----- shared helpers -----
function getReg(ctx: any, userId: string, id: string) {
  const r = ctx.db.registration.registration_id.find(id);
  if (!r || r.user_id !== userId) fail('not_found', `Registration ${id} not found.`);
  return r;
}
function getVehicle(ctx: any, userId: string, vehicleId: string) {
  const v = ctx.db.vehicle.vehicle_id.find(vehicleId);
  if (!v || v.user_id !== userId) fail('not_found', `Vehicle ${vehicleId} not found.`);
  return v;
}
function save(ctx: any, r: any) {
  ctx.db.registration.registration_id.update({ ...r, updated_at: iso(ctx) });
}

// History row for every status change except drafts and dry runs; confirmed ones also update saved places.
function recordStatus(ctx: any, r: any) {
  if (SKIP_HISTORY.includes(r.status) || r.dry_run) return;
  const proof = r.proof_json ? JSON.parse(r.proof_json) : {};
  const row = {
    registration_id: r.registration_id, user_id: r.user_id, property_id: r.property_id,
    property_name: r.property_name, plate: r.plate, unit: r.host_unit, status: r.status,
    confirmation_number: proof.confirmation_number || '', expires_at: proof.expires_at || '',
    created_at: r.created_at_ms || r.created_at, updated_at: isoMs(ctx),
  };
  const old = ctx.db.parking_history.registration_id.find(r.registration_id);
  if (old) ctx.db.parking_history.registration_id.update({ ...row, created_at: old.created_at });
  else ctx.db.parking_history.insert(row);
  if (r.status === 'confirmed') {
    const pid = placeId(r.user_id, r.property_id, r.host_unit, r.host_name);
    const p = ctx.db.saved_place.place_id.find(pid);
    if (p) {
      ctx.db.saved_place.place_id.update({ ...p, property_name: r.property_name, vehicle_id: r.vehicle_id,
        plate: r.plate, duration_hours: r.duration_hours, uses: p.uses + 1, last_used_at: isoMs(ctx) });
    } else {
      ctx.db.saved_place.insert({ place_id: pid, user_id: r.user_id, property_id: r.property_id,
        property_name: r.property_name, unit: r.host_unit, host_name: r.host_name, vehicle_id: r.vehicle_id,
        plate: r.plate, duration_hours: r.duration_hours, label: '', uses: 1,
        first_used_at: isoMs(ctx), last_used_at: isoMs(ctx) });
    }
  }
}
function setStatus(ctx: any, r: any, status: string, extra: any = {}) {
  const next = { ...r, ...extra, status };
  save(ctx, next);
  recordStatus(ctx, next);
}

function bestPlace(ctx: any, userId: string, propertyId: string) {
  let best: any = null;
  for (const p of ctx.db.saved_place.user_id.filter(userId)) {
    if (p.property_id === propertyId && (!best || p.last_used_at > best.last_used_at)) best = p;
  }
  return best;
}

function guestNightsUsed(ctx: any, userId: string, propertyId: string, exceptId: string): number {
  const month = ctx.timestamp.toISOString().slice(0, 7);
  let n = 0;
  for (const r of ctx.db.registration.user_id.filter(userId)) {
    if (r.property_id === propertyId && r.role === 'visitor' && COUNTED.includes(r.status)
      && r.created_at.startsWith(month) && r.registration_id !== exceptId && !r.dry_run) n++;
  }
  return n;
}

function summaryFor(ctx: any, veh: any, propName: string, role: string, hostName: string, hostUnit: string, hours: number) {
  const car = `${veh.model} (${veh.state} ${veh.plate})`;
  let who = 'as a resident';
  if (role !== 'resident') {
    who = hostName ? `as ${hostName}'s guest` : 'as a guest';
    if (hostUnit) who += `, unit ${hostUnit}`;
  }
  return `Register your ${car} at ${propName} ${who}, until ${untilText(ctx.timestamp.toDate(), hours)}?`;
}

// Fills a standard (portal) registration row after checking the property rules.
function fillStandard(ctx: any, base: any, a: { vehicle_id: string; property_id: string; role: string;
  host_name: string; host_unit: string; duration_hours: number }) {
  const veh = getVehicle(ctx, base.user_id, a.vehicle_id);
  const prop = ctx.db.property.property_id.find(a.property_id);
  if (!prop) fail('not_found', `Property ${a.property_id} not found.`);
  if (a.role !== 'resident' && a.role !== 'visitor') fail('validation_error', 'role must be resident or visitor.');
  if (!prop.vendor_id || !prop.portal_path) {
    fail('validation_error', `${prop.name} has no guest registration portal. ${prop.notes || ''}`.trim());
  }
  if (a.duration_hours > prop.max_duration_hours) {
    fail('validation_error', `${prop.name} allows at most ${prop.max_duration_hours} hours per guest registration.`);
  }
  if (a.role === 'visitor' && guestNightsUsed(ctx, base.user_id, prop.property_id, base.registration_id) >= prop.max_nights_per_month) {
    fail('validation_error', `guest night limit reached: ${prop.name} allows ${prop.max_nights_per_month} guest nights per month.`);
  }
  let hostName = a.role === 'resident' ? '' : a.host_name;
  let hostUnit = a.role === 'resident' ? '' : a.host_unit;
  if (a.role === 'visitor' && !hostUnit) {           // same place as before: reuse what they entered
    const saved = bestPlace(ctx, base.user_id, prop.property_id);
    if (saved) { hostName = hostName || saved.host_name; hostUnit = saved.unit; }
  }
  const alternatives = [...ctx.db.property.iter()]
    .filter((o: any) => o.property_id !== prop.property_id)
    .map((o: any) => ({ d: haversineM(prop.lat, prop.lng, o.lat, o.lng), property_id: o.property_id, name: o.name }))
    .sort((x: any, y: any) => x.d - y.d).slice(0, 2).map((o: any) => ({ property_id: o.property_id, name: o.name }));
  return {
    ...base, status: 'awaiting_confirm', flow: 'standard', property_id: prop.property_id, property_name: prop.name,
    vehicle_id: veh.vehicle_id, plate: veh.plate, state: veh.state, make: veh.make, model: veh.model, color: veh.color,
    role: a.role, host_name: hostName, host_unit: hostUnit, duration_hours: a.duration_hours,
    summary: summaryFor(ctx, veh, prop.name, a.role, hostName, hostUnit, a.duration_hours),
    alternatives_json: JSON.stringify(alternatives),
    steps_json: JSON.stringify([{ name: 'match_property', status: 'done', at: iso(ctx) }]),
    needs_user_json: '', proof_json: '', error_json: '',
  };
}

function blankReg(ctx: any, registrationId: string, userId: string) {
  return {
    registration_id: registrationId, user_id: userId, status: 'drafted', flow: 'standard', property_id: '',
    property_name: '', vehicle_id: '', plate: '', state: '', make: '', model: '', color: '', role: 'visitor',
    host_name: '', host_unit: '', duration_hours: 0, summary: '', alternatives_json: '[]', steps_json: '[]',
    needs_user_json: '', proof_json: '', error_json: '', answers_json: '{}', guest_json: '{}', override: false,
    captcha_cleared: false, dry_run: false, reminded: false, run_state: '', confirmed_via: '',
    created_at: iso(ctx), created_at_ms: isoMs(ctx), updated_at: iso(ctx),
  };
}

// ----- properties -----
// The API sends data/properties.json as text on startup; only the rule fields are kept.
export const load_properties = spacetimedb.reducer({ properties_json: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  for (const p of JSON.parse(a.properties_json)) {
    const gr = p.guest_rules || {};
    const row = {
      property_id: String(p.property_id), name: String(p.name), campus: String(p.campus || ''),
      lat: Number(p.lat), lng: Number(p.lng), vendor_id: p.vendor_id || '', property_code: p.property_code || '',
      portal_path: p.portal_path || '', max_nights_per_month: Number(gr.max_nights_per_month || 0),
      max_duration_hours: Number(gr.max_duration_hours || 0), requires_host_unit: !!gr.requires_host_unit,
      notes: p.notes || '',
    };
    if (ctx.db.property.property_id.find(row.property_id)) ctx.db.property.property_id.update(row);
    else ctx.db.property.insert(row);
  }
});

// ----- drafting and the user's decisions -----
export const draft_registration = spacetimedb.reducer({
  registration_id: t.string(), user_id: t.string(), vehicle_id: t.string(), property_id: t.string(),
  role: t.string(), host_name: t.string(), host_unit: t.string(), duration_hours: t.u32(),
}, (ctx, a) => {
  requireOwner(ctx);
  const row = fillStandard(ctx, blankReg(ctx, a.registration_id, a.user_id), a);
  ctx.db.registration.insert({ ...row, status: 'awaiting_confirm' });
});

// Empty string / 0 means "leave as is"; host_set says whether host_name and host_unit replace the old host.
export const patch_registration = spacetimedb.reducer({
  user_id: t.string(), registration_id: t.string(), vehicle_id: t.string(), property_id: t.string(),
  role: t.string(), host_set: t.bool(), host_name: t.string(), host_unit: t.string(), duration_hours: t.u32(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = getReg(ctx, a.user_id, a.registration_id);
  if (r.status !== 'awaiting_confirm') fail('wrong_state', 'Only a registration awaiting confirmation can be edited.');
  const next = fillStandard(ctx, r, {
    vehicle_id: a.vehicle_id || r.vehicle_id, property_id: a.property_id || r.property_id, role: a.role || r.role,
    host_name: a.host_set ? a.host_name : r.host_name, host_unit: a.host_set ? a.host_unit : r.host_unit,
    duration_hours: a.duration_hours || r.duration_hours,
  });
  save(ctx, next);
});

export const cancel_registration = spacetimedb.reducer({ user_id: t.string(), registration_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = getReg(ctx, a.user_id, a.registration_id);
  if (!['awaiting_confirm', 'needs_user', 'drafted'].includes(r.status)) {
    fail('wrong_state', `Cannot cancel a registration that is ${r.status}.`);
  }
  setStatus(ctx, r, 'cancelled', { needs_user_json: '', run_state: '' });
});

// The consent gate: the only way a registration reaches the worker.
export const confirm_registration = spacetimedb.reducer({
  user_id: t.string(), registration_id: t.string(), channel: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = getReg(ctx, a.user_id, a.registration_id);
  const p = ctx.db.profile.user_id.find(a.user_id);
  if (!p || !p.consent_register) fail('consent_required', 'Enable consent to let Parkour register for you.');
  if (r.status !== 'awaiting_confirm') fail('wrong_state', `Registration is ${r.status}, not awaiting_confirm.`);
  setStatus(ctx, r, 'submitting', { confirmed_via: a.channel, run_state: '' });
});

export const answer_registration = spacetimedb.reducer({
  user_id: t.string(), registration_id: t.string(), field: t.string(), value: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = getReg(ctx, a.user_id, a.registration_id);
  const nu = r.needs_user_json ? JSON.parse(r.needs_user_json) : null;
  if (r.status !== 'needs_user' || !nu) fail('wrong_state', 'This registration is not waiting for an answer.');
  const extra: any = { needs_user_json: '', run_state: '' };
  if (nu.reason === 'rule_conflict') {
    if (a.field !== 'override') fail('validation_error', "Answer the rule conflict with field 'override'.");
    if (a.value.trim().toLowerCase() !== 'true') {
      setStatus(ctx, r, 'cancelled', extra);
      return;
    }
    extra.override = true;
  } else if (nu.reason === 'missing_info' && nu.field === 'resident_phone') {
    if (a.field !== 'resident_phone') fail('validation_error', "Expected an answer for 'resident_phone'.");
    const phone = a.value.replace(/[\s()-]/g, '');
    if (!/^\+[1-9]\d{6,14}$/.test(phone)) fail('validation_error', 'Enter the number with country code, like +14695550100.');
    const me = ctx.db.profile.user_id.find(a.user_id);
    if (me && me.phone === phone) fail('validation_error', "That's your own number. Enter the resident's.");
    // At most 3 texts to residents per hour per person, so this cannot be used to spam strangers.
    const since = new Date(ctx.timestamp.toDate().getTime() - 3600_000).toISOString();
    let recent = 0;
    for (const o of ctx.db.registration.user_id.filter(a.user_id)) {
      const at = JSON.parse(o.answers_json || '{}').resident_requested_at;
      if (at && at >= since) recent++;
    }
    if (recent >= 3) fail('rate_limited', 'Too many resident requests. Try again in an hour.');
    const answers = JSON.parse(r.answers_json || '{}');
    answers.resident_phone = phone;
    answers.resident_requested_at = isoMs(ctx);
    const waiting = {
      reason: 'resident_info', field: null, portal_url: null,
      message: `Waiting for the resident (ending ${phone.slice(-4)}) to text back their unit number and last name.`,
    };
    // Stays in needs_user: the worker does nothing until the resident replies.
    setStatus(ctx, r, 'needs_user', { answers_json: JSON.stringify(answers), needs_user_json: JSON.stringify(waiting), run_state: '' });
    return;
  } else if (nu.reason === 'missing_info') {
    if (a.field !== nu.field) fail('validation_error', `Expected an answer for '${nu.field}'.`);
    if (!a.value.trim()) fail('validation_error', 'Answer cannot be empty.');
    const answers = JSON.parse(r.answers_json || '{}');
    answers[a.field] = a.value.trim();
    extra.answers_json = JSON.stringify(answers);
    if (a.field === 'host_unit') extra.host_unit = a.value.trim();
    if (a.field === 'host_name') extra.host_name = a.value.trim();
  } else {
    fail('wrong_state', 'This registration needs resume, not an answer.');
  }
  setStatus(ctx, r, 'submitting', extra);
});

export const resume_registration = spacetimedb.reducer({ user_id: t.string(), registration_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = getReg(ctx, a.user_id, a.registration_id);
  const nu = r.needs_user_json ? JSON.parse(r.needs_user_json) : null;
  if (r.status !== 'needs_user' || !nu || nu.reason !== 'captcha') fail('wrong_state', 'This registration is not waiting on a CAPTCHA.');
  setStatus(ctx, r, 'submitting', { captcha_cleared: true, needs_user_json: '', run_state: '' });
});

export const renew_registration = spacetimedb.reducer({
  user_id: t.string(), registration_id: t.string(), new_registration_id: t.string(), duration_hours: t.u32(),
}, (ctx, a) => {
  requireOwner(ctx);
  const prev = getReg(ctx, a.user_id, a.registration_id);
  if (!['confirmed', 'expired', 'finished'].includes(prev.status)) fail('wrong_state', 'Only an active or past pass can be renewed.');
  const row = fillStandard(ctx, blankReg(ctx, a.new_registration_id, a.user_id), {
    vehicle_id: prev.vehicle_id, property_id: prev.property_id, role: prev.role,
    host_name: prev.host_name, host_unit: prev.host_unit, duration_hours: a.duration_hours,
  });
  ctx.db.registration.insert({ ...row, status: 'awaiting_confirm' });
});

// Maverick Place: the request itself is the user's approval, so this starts in `submitting`.
export const start_maverick = spacetimedb.reducer({
  registration_id: t.string(), user_id: t.string(), vehicle_id: t.string(), unit: t.string(),
  resident_last_name: t.string(), guest_json: t.string(), dry_run: t.bool(),
}, (ctx, a) => {
  requireOwner(ctx);
  const p = ctx.db.profile.user_id.find(a.user_id);
  if (!p || !p.consent_register) fail('consent_required', 'Enable consent to let Parkour register for you.');
  const veh = getVehicle(ctx, a.user_id, a.vehicle_id);
  let unit = a.unit.trim(), resident = a.resident_last_name.trim();
  if (!unit || !resident) {                          // been here before: reuse the unit and resident from last time
    const saved = bestPlace(ctx, a.user_id, 'maverick-place');
    if (saved) { unit = unit || saved.unit; resident = resident || saved.host_name; }
  }
  const base = blankReg(ctx, a.registration_id, a.user_id);
  if (!unit || !resident) {
    // First visit and nothing saved: ask the visitor for the resident's phone number. The resident then
    // confirms their unit and last name by text (see answer_registration and resident_reply).
    const ask = {
      reason: 'missing_info', field: 'resident_phone', portal_url: null,
      message: "Enter the phone number of the resident you're visiting. We'll text them to confirm their unit.",
    };
    const waiting = {
      ...base, flow: 'maverick', status: 'needs_user', dry_run: a.dry_run, property_id: 'maverick-place',
      property_name: 'Maverick Place', vehicle_id: veh.vehicle_id, plate: veh.plate, state: veh.state, make: veh.make,
      model: veh.model, color: veh.color, role: 'visitor', host_name: resident, host_unit: unit, duration_hours: 24,
      summary: `Register your ${veh.model} (${veh.state} ${veh.plate}) at Maverick Place, Day Pass?`,
      steps_json: JSON.stringify([{ name: 'match_property', status: 'done', at: iso(ctx) }]), guest_json: a.guest_json,
      needs_user_json: JSON.stringify(ask), confirmed_via: 'app',
    };
    ctx.db.registration.insert(waiting);
    recordStatus(ctx, waiting);
    return;
  }
  const row = {
    ...base, flow: 'maverick', status: 'submitting', dry_run: a.dry_run, property_id: 'maverick-place',
    property_name: 'Maverick Place', vehicle_id: veh.vehicle_id, plate: veh.plate, state: veh.state, make: veh.make,
    model: veh.model, color: veh.color, role: 'visitor', host_name: resident, host_unit: unit, duration_hours: 24,
    summary: `Register your ${veh.model} (${veh.state} ${veh.plate}) at Maverick Place as a guest of unit ${unit}, Day Pass?`,
    steps_json: JSON.stringify([{ name: 'match_property', status: 'done', at: iso(ctx) }]), guest_json: a.guest_json,
    confirmed_via: 'app',
  };
  ctx.db.registration.insert(row);
  recordStatus(ctx, row);
});

// ----- the worker (agent/worker.py) -----
// A worker takes a `submitting` registration with claim_registration, then reports progress with these.
export const claim_registration = spacetimedb.reducer({ registration_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (!r || r.status !== 'submitting' || r.run_state !== '') fail('not_claimable', 'Already taken or not submitting.');
  save(ctx, { ...r, run_state: 'running' });
});

// On worker start: anything a crashed worker was holding goes back in the queue.
export const release_stuck = spacetimedb.reducer((ctx) => {
  requireOwner(ctx);
  for (const r of [...ctx.db.registration.status.filter('submitting')]) {
    if (r.run_state === 'running') save(ctx, { ...r, run_state: '' });
  }
});

export const reg_step = spacetimedb.reducer({
  registration_id: t.string(), name: t.string(), status: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (!r) return;
  const steps = JSON.parse(r.steps_json);
  const at = iso(ctx);
  const s = steps.find((x: any) => x.name === a.name);
  if (s) { s.status = a.status; s.at = at; } else steps.push({ name: a.name, status: a.status, at });
  save(ctx, { ...r, steps_json: JSON.stringify(steps) });
});

export const reg_needs_user = spacetimedb.reducer({ registration_id: t.string(), needs_user_json: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r) setStatus(ctx, r, 'needs_user', { needs_user_json: a.needs_user_json, run_state: '' });
});

export const reg_confirmed = spacetimedb.reducer({ registration_id: t.string(), proof_json: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r) setStatus(ctx, r, 'confirmed', { proof_json: a.proof_json, needs_user_json: '', error_json: '', run_state: '' });
});

export const reg_failed = spacetimedb.reducer({
  registration_id: t.string(), code: t.string(), message: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r) setStatus(ctx, r, 'failed', { error_json: JSON.stringify({ code: a.code, message: a.message }), needs_user_json: '', run_state: '' });
});

// A dry run fills the form but submits nothing; it ends as `cancelled` and leaves no history.
export const reg_dry_run_done = spacetimedb.reducer({
  registration_id: t.string(), summary: t.string(), proof_json: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r) setStatus(ctx, r, 'cancelled', { summary: a.summary, proof_json: a.proof_json, needs_user_json: '', run_state: '' });
});

export const reg_expire = spacetimedb.reducer({ registration_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r && r.status === 'confirmed') setStatus(ctx, r, 'expired');
});

export const reg_mark_reminded = spacetimedb.reducer({ registration_id: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = ctx.db.registration.registration_id.find(a.registration_id);
  if (r) save(ctx, { ...r, reminded: true });
});

// ----- the resident's reply (Maverick Place) -----
function waitingForResident(ctx: any, registrationId: string) {
  const r = ctx.db.registration.registration_id.find(registrationId);
  const nu = r && r.needs_user_json ? JSON.parse(r.needs_user_json) : null;
  if (!r || r.status !== 'needs_user' || !nu || nu.reason !== 'resident_info') {
    fail('wrong_state', 'This registration is not waiting for a resident.');
  }
  return r;
}

export const resident_reply = spacetimedb.reducer({
  registration_id: t.string(), unit: t.string(), last_name: t.string(),
}, (ctx, a) => {
  requireOwner(ctx);
  const r = waitingForResident(ctx, a.registration_id);
  const unit = a.unit.trim(), last = a.last_name.trim();
  if (!unit || unit.length > 20 || !last || last.length > 60) fail('validation_error', 'Need a unit number and a last name.');
  setStatus(ctx, r, 'submitting', { host_unit: unit, host_name: last, needs_user_json: '', run_state: '' });
});

export const resident_decline = spacetimedb.reducer({ registration_id: t.string(), code: t.string(), message: t.string() }, (ctx, a) => {
  requireOwner(ctx);
  const r = waitingForResident(ctx, a.registration_id);
  setStatus(ctx, r, 'failed', { error_json: JSON.stringify({ code: a.code, message: a.message }), needs_user_json: '', run_state: '' });
});

// ----- test support: refuses unless enable_dev_mode was called on this database -----
export const enable_dev_mode = spacetimedb.reducer((ctx) => {
  requireOwner(ctx);
  if (!ctx.db.config.key.find('dev_mode')) ctx.db.config.insert({ key: 'dev_mode', value: '1' });
});

export const dev_wipe = spacetimedb.reducer((ctx) => {
  requireOwner(ctx);
  if (!ctx.db.config.key.find('dev_mode')) fail('not_allowed', 'dev mode is off');
  for (const r of [...ctx.db.registration.iter()]) ctx.db.registration.registration_id.delete(r.registration_id);
  for (const r of [...ctx.db.parking_history.iter()]) ctx.db.parking_history.registration_id.delete(r.registration_id);
  for (const r of [...ctx.db.saved_place.iter()]) ctx.db.saved_place.place_id.delete(r.place_id);
  for (const r of [...ctx.db.vehicle.iter()]) ctx.db.vehicle.vehicle_id.delete(r.vehicle_id);
  for (const r of [...ctx.db.session.iter()]) ctx.db.session.token_hash.delete(r.token_hash);
  for (const r of [...ctx.db.credential.iter()]) ctx.db.credential.user_id.delete(r.user_id);
  for (const r of [...ctx.db.profile.iter()]) ctx.db.profile.user_id.delete(r.user_id);
});
