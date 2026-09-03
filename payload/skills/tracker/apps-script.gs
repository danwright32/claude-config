/**
 * Personal Project Tracker: Apps Script Web App
 *
 * Deploy: Deploy > New deployment > Web app
 *   Execute as: Me
 *   Who has access: Anyone   (the TOKEN below guards writes)
 * Copy the resulting /exec URL into the skill's config.local.json.
 *
 * GET  ?token=...                     -> { ok, headers: [...] }
 * POST { token, data: { Header: val } } -> appends a row, returns { ok, rowNumber, row }
 */

const TOKEN = 'REPLACE_WITH_A_LONG_RANDOM_STRING';
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

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.token !== TOKEN) return json_({ ok: false, error: 'bad token' });
  return json_({ ok: true, headers: headers_(getSheet_()) });
}

function doPost(e) {
  let body = {};
  try {
    body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return json_({ ok: false, error: 'bad json' });
  }
  if (body.token !== TOKEN) return json_({ ok: false, error: 'bad token' });

  const sheet = getSheet_();
  const heads = headers_(sheet);
  const data = body.data || {};

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
