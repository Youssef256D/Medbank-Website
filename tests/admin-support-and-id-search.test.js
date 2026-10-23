'use strict';

// Two rules shared with the Flutter app's admin:
// - an "id" prefix in the Users search matches the MedBank ID only
//   (app: AdminUserQuery.explicitPublicUserIdSearch);
// - the support WhatsApp number is stored as digits with a country code
//   (app: core/config/support_number.dart).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const vm = require('vm');

const mainSource = fs.readFileSync('main.js', 'utf8');
const topLevelFunction = (name) => {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf('\n}\n', start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return mainSource.slice(start, end) + '\n}\n';
};

const context = vm.createContext({});
[
  'getExplicitAdminUserIdSearch',
  'isValidSupportWhatsAppNumber',
  'normalizeSupportWhatsAppNumber',
  'formatSupportWhatsAppNumber',
].forEach((name) => vm.runInContext(topLevelFunction(name), context));

test('an "id" prefix asks for the MedBank ID only', () => {
  for (const search of ['id 1042', 'ID:1042', 'id: 1042', 'Id1042', '#1042', ' id=1042 ']) {
    assert.strictEqual(context.getExplicitAdminUserIdSearch(search), '1042', search);
  }
});

test('names and bare numbers are not an explicit id search', () => {
  for (const search of ['Idris', '1042', 'id', 'id abc', '01001234567']) {
    assert.strictEqual(context.getExplicitAdminUserIdSearch(search), '', search);
  }
});

test('support numbers normalize the way the app does', () => {
  assert.strictEqual(context.normalizeSupportWhatsAppNumber('+20 155 290 0540'), '201552900540');
  assert.strictEqual(context.normalizeSupportWhatsAppNumber('01552900540'), '201552900540');
  assert.strictEqual(context.normalizeSupportWhatsAppNumber('00201552900540'), '201552900540');
  assert.strictEqual(context.normalizeSupportWhatsAppNumber('+44 7700-900123'), '447700900123');
  assert.ok(context.isValidSupportWhatsAppNumber('201552900540'));
  assert.ok(!context.isValidSupportWhatsAppNumber('1234567'));
  assert.ok(!context.isValidSupportWhatsAppNumber('1234567890123456'));
  assert.strictEqual(context.formatSupportWhatsAppNumber('201552900540'), '+20 155 290 0540');
  assert.strictEqual(context.formatSupportWhatsAppNumber('447700900123'), '+447700900123');
});
