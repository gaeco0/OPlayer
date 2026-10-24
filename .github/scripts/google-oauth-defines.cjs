// Values arrive through environment variables, never shell interpolation/logs.
const fs = require('node:fs');
const path = require('node:path');

function writeDefines(platform, destination, env = process.env) {
  if (!['android', 'desktop'].includes(platform)) throw new Error('Expected android or desktop');
  const keys = platform === 'android'
    ? ['OPLAYER_GOOGLE_ANDROID_CLIENT_ID']
    : ['OPLAYER_GOOGLE_DESKTOP_CLIENT_ID', 'OPLAYER_GOOGLE_DESKTOP_CLIENT_SECRET'];
  const values = Object.fromEntries(keys.map(key => [key, (env[key] || '').trim()]));
  const id = values[keys[0]];
  if (id && !/^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(id)) {
    throw new Error('Invalid Google OAuth Client ID');
  }
  if (platform === 'desktop' && Boolean(id) !== Boolean(values[keys[1]])) {
    throw new Error('Configure both Google desktop Client ID and Client Secret');
  }
  fs.mkdirSync(path.dirname(destination), {recursive: true});
  fs.writeFileSync(destination, JSON.stringify(values), {mode: 0o600});
}
if (require.main === module) writeDefines(process.argv[2], '.dart_tool/google-oauth-defines.json');
module.exports = {writeDefines};
