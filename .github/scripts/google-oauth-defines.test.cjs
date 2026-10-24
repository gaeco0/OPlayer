const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {writeDefines} = require('./google-oauth-defines.cjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'oplayer-oauth-test-'));
const file = path.join(root, 'defines.json');
const env = {
  OPLAYER_GOOGLE_ANDROID_CLIENT_ID: 'android.apps.googleusercontent.com',
  OPLAYER_GOOGLE_DESKTOP_CLIENT_ID: 'desktop.apps.googleusercontent.com',
  OPLAYER_GOOGLE_DESKTOP_CLIENT_SECRET: 'desktop-secret-"\\$`\n',
  UNRELATED_TOKEN: 'never-export',
};
try {
  writeDefines('android', file, env);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)), {OPLAYER_GOOGLE_ANDROID_CLIENT_ID: env.OPLAYER_GOOGLE_ANDROID_CLIENT_ID});
  writeDefines('desktop', file, env);
  const values = JSON.parse(fs.readFileSync(file));
  assert.equal(values.OPLAYER_GOOGLE_DESKTOP_CLIENT_SECRET, env.OPLAYER_GOOGLE_DESKTOP_CLIENT_SECRET.trim());
  assert.equal(Object.keys(values).length, 2);
  writeDefines('desktop', file, {});
  assert.equal(JSON.parse(fs.readFileSync(file)).OPLAYER_GOOGLE_DESKTOP_CLIENT_ID, '');
  assert.throws(() => writeDefines('desktop', file, {OPLAYER_GOOGLE_DESKTOP_CLIENT_ID: env.OPLAYER_GOOGLE_DESKTOP_CLIENT_ID}));
  assert.throws(() => writeDefines('android', file, {OPLAYER_GOOGLE_ANDROID_CLIENT_ID: 'invalid'}));
  console.log('Google OAuth build configuration checks passed');
} finally {
  fs.rmSync(root, {recursive: true, force: true});
}
