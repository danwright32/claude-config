/**
 * Personal Project Tracker: Apps Script Web App
 *
 * Deploy: Deploy > New deployment > Web app
 *   Execute as: Me
 *   Who has access: Anyone   (the TOKEN below guards every request)
 * Copy the resulting /exec URL into the skill's config.local.json.
 *
 * Every request is a POST with the key in its BODY, never the address, so Google's request
 * logs never record it (claude-config#675):
 *   POST { key, action: "headers" }               -> { ok, headers: [...] }
 *   POST { key, data: { Header: val } }           -> appends a row, returns { ok, rowNumber, row }
 *   POST { key, action: "update", link, projectName, cells: { Header: val } }
 *        -> changes ONLY the named cells of the one row whose Link is `link`, once that row's
 *           Project Name is confirmed to be `projectName`; every other cell is never written.
 *           Returns { ok, action: "update", rowNumber, before: { Header: old }, row, headers }.
 *           With preview: true it checks the same way, writes nothing, and answers
 *           { ok, action: "update", preview: true, rowNumber, before, row, headers }.
 *           With expect: { Header: value } (the preview's before) it writes only while each of
 *           those cells still holds that value, so an edit since the preview is never lost.
 *           Text is written as literal text (never a formula, date or number); every answer
 *           carries `restore`, the values that put the cells back, a formula as { formula } and
 *           a date as { date }; only restore: true (with expect covering every cell) accepts
 *           those marked values, as an undo.
 * append writes every text value as literal text too.
 * The body field is "key", not "token": the first version of this script read "token", so a
 * caller written for one version is refused by the other rather than half understood. For the
 * same reason an update carries its cells as "cells", never "data": a script deployed before
 * update reads any "data" object as a row to append, and refuses a body without one.
 *
 * Changing this file changes nothing live until it is pasted into the sheet's Apps Script and
 * deployed as a new version (Deploy, Manage deployments, Edit, New version); see SKILL.md.
 *
 * Until TOKEN below is changed from the placeholder, every request is refused: the placeholder
 * is public, in the repository this file comes from.
 */

const TOKEN = 'REPLACE_WITH_A_LONG_RANDOM_STRING';
const TOKEN_PLACEHOLDER = 'REPLACE_WITH_A_LONG_RANDOM_STRING';
const TOKEN_MIN_LENGTH = 32;
const SHEET_NAME = ''; // leave blank to use the first sheet

function getSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  return SHEET_NAME ? ss.getSheetByName(SHEET_NAME) : ss.getSheets()[0];
}

function headers_(sheet) {
  const lastCol = sheet.getLastColumn();
  if (lastCol === 0) return [];
  return sheet.getRange(1, 1, 1, lastCol).getValues()[0].map(String);
}

function json_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// Fails closed: a TOKEN never changed from the public placeholder, or too short to be a real
// one, refuses every request whatever the caller sends.
function tokenProblem_(given) {
  if (typeof TOKEN !== 'string' || TOKEN === TOKEN_PLACEHOLDER || TOKEN.length < TOKEN_MIN_LENGTH) {
    return 'token not set: replace the TOKEN line in this script, then deploy a new version';
  }
  if (!sameSecret_(given, TOKEN)) return 'bad token';
  return '';
}

// Constant time: every character of the expected value is read whatever the caller sent, so
// how long a refusal takes says nothing about how much of a guess was right.
function sameSecret_(given, expected) {
  if (typeof given !== 'string') return false;
  let diff = given.length ^ expected.length;
  for (let i = 0; i < expected.length; i++) {
    const g = i < given.length ? given.charCodeAt(i) : 0;
    diff |= g ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

// GET carries its parameters in the address, which is logged, so it is refused outright.
function doGet(e) {
  return json_({ ok: false, error: 'use POST with the key in the body' });
}

function doPost(e) {
  let body = {};
  try {
    body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return json_({ ok: false, error: 'bad json' });
  }
  if (!body || typeof body !== 'object') return json_({ ok: false, error: 'bad json' });
  const problem = tokenProblem_(body.key);
  if (problem) return json_({ ok: false, error: problem });

  const sheet = getSheet_();
  if (body.action === 'update') return json_(update_(sheet, body));
  // Anything else that names an action is refused: a mistyped "update" must never fall through
  // to the append below and add a row.
  if (body.action !== undefined && body.action !== 'headers' && body.action !== 'append') {
    return json_({ ok: false, error: 'unknown action "' + String(body.action) + '": send "headers", "append" or "update"' });
  }
  const heads = headers_(sheet);
  if (body.action === 'headers') return json_({ ok: true, headers: heads });
  if (!body.data || typeof body.data !== 'object') {
    return json_({ ok: false, error: 'nothing to append: send action "headers" or a data object' });
  }
  const data = body.data;

  const norm = norm_;
  // A Map, never a plain object, so a column named "constructor" is not found on Object.prototype.
  const byHeader = new Map();
  const dataKeys = Object.keys(data);
  for (let i = 0; i < dataKeys.length; i++) {
    const problem = cellValueProblem_(dataKeys[i], data[dataKeys[i]], false);
    if (problem) return json_({ ok: false, error: problem + '; nothing was appended' });
    byHeader.set(norm(dataKeys[i]), data[dataKeys[i]]);
  }

  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');

  const row = heads.map(function (h) {
    const key = norm(h);
    if (byHeader.has(key)) return cellInput_(byHeader.get(key));
    // A real date, like a { date } a caller sends and the dates already in the sheet. The script
    // makes this value itself, so it carries nothing a caller wrote.
    if (/(date|timestamp|added|updated|created)/.test(key)) return today;
    return '';
  });

  sheet.appendRow(row);
  // Answer with the row as the sheet shows it, never the escaped values handed to appendRow.
  const rowNumber = sheet.getLastRow();
  const shown = sheet.getRange(rowNumber, 1, 1, heads.length).getDisplayValues()[0];
  return json_({ ok: true, rowNumber: rowNumber, row: shown, headers: heads });
}

function norm_(s) { return String(s).trim().toLowerCase(); }

// Every text value a caller sends is written as LITERAL text: Sheets reads a leading apostrophe
// as "store the rest as text" and does not show it. Without it, text starting = + - or @ becomes
// a live formula (text built from commit subjects could run IMPORTXML and send the sheet's
// contents anywhere), and date or number shaped text is converted. Numbers and true or false,
// sent as such, carry no formula and are written as they are. Only update's restore (an undo)
// writes raw, so it can put a formula or a date back.
function literal_(v) {
  return typeof v === 'string' && v !== '' ? "'" + v : v;
}

// A real calendar date, yyyy-mm-dd: the only shape a { date } value may take, so a date mark can
// never carry a formula into the sheet.
const DATE_PATTERN = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

// What, written back with restore, puts a cell back as it is: a formula as { formula }, a date as
// { date } in yyyy-mm-dd, text as text, and a number or true or false as itself. Marked objects
// rather than raw strings, so a restore never needs an apostrophe a shell cannot quote, and plain
// text stays literal even then. Dates are told apart with toString, which works for a Date from
// any realm, where instanceof does not.
function restoreValue_(rawValue, formula) {
  if (formula) return { formula: formula };
  if (Object.prototype.toString.call(rawValue) === '[object Date]') {
    return { date: Utilities.formatDate(rawValue, Session.getScriptTimeZone(), 'yyyy-MM-dd') };
  }
  return rawValue;
}

// The value setValue or appendRow is given: a marked formula or date raw, so Sheets makes it a
// formula or a real date; anything else literal.
function cellInput_(v) {
  if (v && typeof v === 'object') return v.formula !== undefined ? v.formula : v.date;
  return literal_(v);
}

// A value append or update accepts: text, a number, true or false; a { date: "yyyy-mm-dd" } for a
// real date, like the dates already in the sheet; and, with restore only (an undo), a
// { formula: "=..." }. Each mark is an object of that single key. Returns a refusal or ''.
function cellValueProblem_(header, v, restore) {
  if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') return '';
  if (v && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 1) {
    if (v.date !== undefined) {
      if (typeof v.date === 'string' && DATE_PATTERN.test(v.date)) return '';
      return 'the date for "' + header + '" must be a real date written yyyy-mm-dd';
    }
    if (v.formula !== undefined) {
      if (!restore) return 'a { formula } value for "' + header + '" is written only with restore: true (an undo)';
      if (typeof v.formula === 'string' && v.formula.charAt(0) === '=') return '';
    }
  }
  return 'the value for "' + header + '" must be text, a number, true or false, or { date: "yyyy-mm-dd" } (or, with restore, { formula: "=..." })';
}

// How long an update waits for another request that is writing the sheet, before refusing.
const LOCK_WAIT_MS = 10000;

// update: change named cells of ONE existing row, found by its Link. Only the cells named in
// `cells` are ever written; every other cell of the row (When to Check Results, a column added
// next year) is left exactly as it is, never read and written back, so nothing the caller did
// not name can be blanked or reformatted.
function update_(sheet, body) {
  const link = typeof body.link === 'string' ? body.link.trim() : '';
  const name = typeof body.projectName === 'string' ? body.projectName.trim() : '';
  if (!link) return { ok: false, error: 'update needs link: the Link of the row to change' };
  if (!name) return { ok: false, error: 'update needs projectName: the Project Name of the row to change' };
  if (body.data !== undefined) {
    return { ok: false, error: 'update takes its cells as "cells", never "data" (a data object is a row to append)' };
  }
  const cells = body.cells;
  if (!cells || typeof cells !== 'object' || Array.isArray(cells) || Object.keys(cells).length === 0) {
    return { ok: false, error: 'nothing to update: send cells, an object of Header: value' };
  }
  // restore (an undo) is the one write that may put a formula or a date back: it accepts the
  // answer's marked { formula } and { date } values, and only with expect covering every cell it
  // writes (checked below), so it can only overwrite the very values it is undoing.
  if (body.restore !== undefined && typeof body.restore !== 'boolean') {
    return { ok: false, error: 'restore must be true or false' };
  }
  const restore = body.restore === true;
  // Each header named once, each value something a cell holds. A Map, never a plain object,
  // so a header named "constructor" is not found on Object.prototype.
  const named = new Map();
  const keys = Object.keys(cells);
  for (let i = 0; i < keys.length; i++) {
    const k = norm_(keys[i]);
    if (named.has(k)) {
      return { ok: false, error: 'cells names the column "' + keys[i] + '" more than once (also as "' + named.get(k) + '")' };
    }
    named.set(k, keys[i]);
    const problem = cellValueProblem_(keys[i], cells[keys[i]], restore);
    if (problem) return { ok: false, error: problem };
  }

  if (body.preview !== undefined && typeof body.preview !== 'boolean') {
    return { ok: false, error: 'preview must be true or false' };
  }
  // expect: what each named cell held when the caller read it (the preview's `before`). The write
  // goes ahead only while every one still holds it, so an edit made after the old values were
  // shown and approved is never overwritten unseen.
  const expect = new Map();
  if (body.expect !== undefined) {
    if (!body.expect || typeof body.expect !== 'object' || Array.isArray(body.expect)) {
      return { ok: false, error: 'expect must be an object of Header: the value read before (the preview\'s before)' };
    }
    const ek = Object.keys(body.expect);
    for (let i = 0; i < ek.length; i++) {
      if (!named.has(norm_(ek[i]))) {
        return { ok: false, error: 'expect names "' + ek[i] + '", which cells does not change' };
      }
      const v = body.expect[ek[i]];
      if (!(typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean')) {
        return { ok: false, error: 'the expected value for "' + ek[i] + '" must be text, a number, or true or false' };
      }
      expect.set(norm_(ek[i]), String(v));
    }
  }
  if (restore) {
    if (body.expect === undefined) {
      return { ok: false, error: 'restore puts formulas and dates back, so it needs expect: what every cell it writes holds now' };
    }
    for (let i = 0; i < keys.length; i++) {
      if (!expect.has(norm_(keys[i]))) {
        return { ok: false, error: 'restore puts formulas and dates back, so expect must cover every cell it writes; it has no "' + keys[i] + '"' };
      }
    }
  }
  // A preview finds and checks the row exactly as the update would, writes nothing, and answers
  // with the named cells' current values, so they can be shown for approval first.
  if (body.preview === true) return findAndUpdate_(sheet, link, name, cells, keys, expect, true);

  // One update at a time, so two runs cannot interleave their checks and writes. A person
  // editing the sheet takes no lock, which is what the re-check below is for.
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(LOCK_WAIT_MS)) {
    return { ok: false, error: 'busy: another request is writing the sheet; nothing was changed, try again' };
  }
  try {
    return findAndUpdate_(sheet, link, name, cells, keys, expect, false);
  } finally {
    lock.releaseLock();
  }
}

// Reads cells as the sheet SHOWS them (getDisplayValues), never getValues: a date cell's value
// is a Date, which reaches the caller as a timestamp nobody typed and would not match the Link
// or Project Name a person sees.
function findAndUpdate_(sheet, link, name, cells, keys, expect, preview) {
  const heads = headers_(sheet);
  const col = new Map(); // normalized header -> 1 based column, or 0 when two columns share it
  heads.forEach(function (h, i) {
    const k = norm_(h);
    if (k) col.set(k, col.has(k) ? 0 : i + 1);
  });
  const columnOf = function (header) {
    const c = col.get(norm_(header));
    if (c === undefined) return { error: 'the sheet has no column named "' + header + '"; nothing was changed' };
    if (c === 0) return { error: 'more than one column is named "' + header + '"; nothing was changed' };
    return { col: c };
  };
  const linkAt = columnOf('Link');
  if (linkAt.error) return { ok: false, error: linkAt.error };
  const nameAt = columnOf('Project Name');
  if (nameAt.error) return { ok: false, error: nameAt.error };
  const targets = [];
  for (let i = 0; i < keys.length; i++) {
    const at = columnOf(keys[i]);
    if (at.error) return { ok: false, error: at.error };
    targets.push({ col: at.col, header: heads[at.col - 1], value: cells[keys[i]] });
  }

  // Find the row: exactly one row may hold this Link. None, or more than one, is a refusal,
  // never a guess at the nearest row.
  const lastRow = sheet.getLastRow();
  const rows = lastRow >= 2 ? sheet.getRange(2, 1, lastRow - 1, heads.length).getDisplayValues() : [];
  const cellText = function (row, c) { return String(row[c - 1] === undefined || row[c - 1] === null ? '' : row[c - 1]).trim(); };
  const matches = [];
  rows.forEach(function (row, i) { if (cellText(row, linkAt.col) === link) matches.push(i + 2); });
  if (matches.length === 0) {
    return { ok: false, error: 'no row has the Link ' + link + '; nothing was changed' };
  }
  if (matches.length > 1) {
    return { ok: false, error: 'more than one row (' + matches.join(', ') + ') has the Link ' + link + '; nothing was changed. Leave the Link on one row, then try again' };
  }
  const rowNumber = matches[0];
  const foundName = cellText(rows[rowNumber - 2], nameAt.col);
  if (foundName !== name) {
    return { ok: false, error: 'the row with that Link (row ' + rowNumber + ') has Project Name "' + foundName + '", not "' + name + '"; nothing was changed' };
  }

  // Re-check straight before writing: a sort, an inserted row or column, or an edit since the
  // read above would otherwise send these cells into another project's row or column.
  const headsNow = headers_(sheet);
  const sameHeads = headsNow.length === heads.length && headsNow.every(function (h, i) { return h === heads[i]; });
  if (!sameHeads) {
    return { ok: false, error: 'the sheet changed while updating (its columns moved); nothing was changed. Read it again and retry' };
  }
  const target = sheet.getRange(rowNumber, 1, 1, heads.length);
  const current = target.getDisplayValues()[0];
  if (cellText(current, linkAt.col) !== link || cellText(current, nameAt.col) !== name) {
    return { ok: false, error: 'the sheet changed while updating (row ' + rowNumber + ' no longer holds Link ' + link + ' and Project Name "' + name + '"); nothing was changed. Read it again and retry' };
  }

  // What each named cell holds: `before` as a person reads it (a formula as its formula, never
  // its result, anything else as the sheet shows it), which is what expect is compared with; and
  // `restore`, what written back with restore puts the cell back exactly (see restoreValue_).
  const formulas = target.getFormulas()[0];
  const rawValues = target.getValues()[0];
  const before = {};
  const restoreWith = {};
  targets.forEach(function (t) {
    before[t.header] = formulas[t.col - 1] || current[t.col - 1];
    restoreWith[t.header] = restoreValue_(rawValues[t.col - 1], formulas[t.col - 1]);
  });
  for (let i = 0; i < targets.length; i++) {
    const want = expect.get(norm_(targets[i].header));
    const has = String(before[targets[i].header]);
    if (want !== undefined && want !== has) {
      return { ok: false, error: 'the cell "' + targets[i].header + '" (row ' + rowNumber + ') now holds "' + has + '", not "' + want + '" as read before; nothing was changed. Preview again and confirm the new values' };
    }
  }
  if (preview) {
    return { ok: true, action: 'update', preview: true, rowNumber: rowNumber, before: before, restore: restoreWith, row: current, headers: heads };
  }
  // One cell at a time, so a cell the caller did not name is never written. If a write fails
  // partway (a protected cell, a quota), the cells already written are put back from `restore`,
  // so the row is never left half changed, and the answer says which cell failed and whether the
  // others went back.
  const written = [];
  try {
    targets.forEach(function (t) {
      sheet.getRange(rowNumber, t.col).setValue(cellInput_(t.value));
      written.push(t);
    });
  } catch (err) {
    const failed = targets[written.length];
    const why = 'writing "' + failed.header + '" (row ' + rowNumber + ') failed: ' + String((err && err.message) || err);
    if (written.length === 0) return { ok: false, error: why + '; nothing had been written', restore: restoreWith };
    const names = written.map(function (t) { return '"' + t.header + '"'; }).join(', ');
    try {
      written.forEach(function (t) { sheet.getRange(rowNumber, t.col).setValue(cellInput_(restoreWith[t.header])); });
      SpreadsheetApp.flush();
    } catch (err2) {
      return { ok: false, error: why + '; ' + names + ' had been written and could NOT be put back (' + String((err2 && err2.message) || err2) + '): undo them with restore', written: written.map(function (t) { return t.header; }), restore: restoreWith };
    }
    return { ok: false, error: why + '; ' + names + ' had been written and were put back, so the row is as it was', restore: restoreWith };
  }
  SpreadsheetApp.flush();
  const row = sheet.getRange(rowNumber, 1, 1, heads.length).getDisplayValues()[0];
  return { ok: true, action: 'update', rowNumber: rowNumber, before: before, restore: restoreWith, row: row, headers: heads };
}
