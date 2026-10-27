// Memvo website waiting list: a Google Apps Script web app that adds each sign-up to a Google Sheet.
// It is not part of the apps. The site has no server, so the Sheet's own script receives the form.
//
// Setup (once):
//   1. Create a Google Sheet. Extensions → Apps Script. Replace Code.gs with this file and save.
//   2. Deploy → New deployment → type "Web app". Execute as: Me. Who has access: Anyone. Deploy and allow access.
//   3. Copy the web app URL (https://script.google.com/macros/s/…/exec) into the waiting-list form's `action`
//      in website/index.html, replacing the PASTE_DEPLOYMENT_ID one. The form only appears once it's set.
// After editing this script: Deploy → Manage deployments → edit → New version, so the URL stays the same.

const SHEET_NAME = "Waiting list";

function doPost(e) {
  const p = (e && e.parameter) || {};
  // Bots fill every field; people never see this one.
  if (p.website) return reply("ok");

  const email = String(p.email || "").trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return reply("invalid");
  const platform = ["iPhone", "Mac", "Both"].includes(p.platform) ? p.platform : "";

  // Two sign-ups at the same moment must not both pass the duplicate check.
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const sheet = waitlistSheet();
    const last = sheet.getLastRow();
    const known = last > 1 ? sheet.getRange(2, 2, last - 1, 1).getValues().flat() : [];
    if (!known.includes(email)) sheet.appendRow([new Date(), email, platform]);
  } finally {
    lock.releaseLock();
  }
  return reply("ok");
}

function waitlistSheet() {
  const book = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = book.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = book.insertSheet(SHEET_NAME);
    sheet.appendRow(["Joined", "Email", "Device"]);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function reply(text) {
  return ContentService.createTextOutput(text).setMimeType(ContentService.MimeType.TEXT);
}
