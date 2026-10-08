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
 * The body field is "key", not "token": the first version of this script read "token", so a
 * caller written for one version is refused by the other rather than half understood.
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
  const heads = headers_(sheet);
  if (body.action === 'headers') return json_({ ok: true, headers: heads });
  if (!body.data || typeof body.data !== 'object') {
    return json_({ ok: false, error: 'nothing to append: send action "headers" or a data object' });
  }
  const data = body.data;

  const norm = function (s) { return String(s).trim().toLowerCase(); };
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
