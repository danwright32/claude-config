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
  const byHeader = {};
  Object.keys(data).forEach(function (k) { byHeader[norm(k)] = data[k]; });

  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');

  const row = heads.map(function (h) {
    const key = norm(h);
    if (key in byHeader) return byHeader[key];
    if (/(date|timestamp|added|updated|created)/.test(key)) return today;
    return '';
  });

  sheet.appendRow(row);
  return json_({ ok: true, rowNumber: sheet.getLastRow(), row: row, headers: heads });
}

function norm_(s) { return String(s).trim().toLowerCase(); }

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
    const v = cells[keys[i]];
    if (!(typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean')) {
      return { ok: false, error: 'the value for "' + keys[i] + '" must be text, a number, or true or false' };
    }
  }

  // One update at a time, so two runs cannot interleave their checks and writes. A person
  // editing the sheet takes no lock, which is what the re-check below is for.
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(LOCK_WAIT_MS)) {
    return { ok: false, error: 'busy: another request is writing the sheet; nothing was changed, try again' };
  }
  try {
    return updateLocked_(sheet, link, name, cells, keys);
  } finally {
    lock.releaseLock();
  }
}

function updateLocked_(sheet, link, name, cells, keys) {
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
  const rows = lastRow >= 2 ? sheet.getRange(2, 1, lastRow - 1, heads.length).getValues() : [];
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
  const current = sheet.getRange(rowNumber, 1, 1, heads.length).getValues()[0];
  if (cellText(current, linkAt.col) !== link || cellText(current, nameAt.col) !== name) {
    return { ok: false, error: 'the sheet changed while updating (row ' + rowNumber + ' no longer holds Link ' + link + ' and Project Name "' + name + '"); nothing was changed. Read it again and retry' };
  }

  const before = {};
  targets.forEach(function (t) { before[t.header] = current[t.col - 1]; });
  targets.forEach(function (t) { sheet.getRange(rowNumber, t.col).setValue(t.value); });
  SpreadsheetApp.flush();
  const row = sheet.getRange(rowNumber, 1, 1, heads.length).getValues()[0];
  return { ok: true, action: 'update', rowNumber: rowNumber, before: before, row: row, headers: heads };
}
