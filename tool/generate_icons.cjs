// Render the shared vector logo with sharp; use the bundled Node package path.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const logo = fs.readFileSync(path.join(root, 'assets/branding/oplayer.svg'));
async function png(file, size, opaque = false) {
  let image = sharp(logo).resize(size, size);
  if (opaque) image = image.flatten({background:'#26262A'});
  fs.mkdirSync(path.dirname(path.join(root, file)), {recursive:true});
  await image.png().toFile(path.join(root, file));
}
(async () => {
  await png('assets/branding/oplayer.png', 1024);
  for (const [density, size] of Object.entries({mdpi:48,hdpi:72,xhdpi:96,xxhdpi:144,xxxhdpi:192})) {
    for (const name of ['ic_launcher','ic_launcher_round']) {
      await png(`android/app/src/main/res/mipmap-${density}/${name}.png`,size);
    }
  }
  for (const platform of ['ios','macos']) {
    const folder = `${platform}/Runner/Assets.xcassets/AppIcon.appiconset`;
    const contents = JSON.parse(fs.readFileSync(path.join(root,folder,'Contents.json'),'utf8'));
    for (const item of contents.images) {
      if (!item.filename) continue;
      await png(`${folder}/${item.filename}`,Math.round(parseFloat(item.size)*parseFloat(item.scale)),platform==='ios');
    }
  }
  const sizes = [16,24,32,48,64,128,256];
  const images = await Promise.all(sizes.map(size=>sharp(logo).resize(size,size).png().toBuffer()));
  const header = Buffer.alloc(6 + sizes.length*16);
  header.writeUInt16LE(1,2); header.writeUInt16LE(sizes.length,4);
  let offset = header.length;
  images.forEach((buffer,i)=>{
    const at=6+i*16, size=sizes[i];
    header[at]=header[at+1]=size===256?0:size;
    header.writeUInt16LE(1,at+4); header.writeUInt16LE(32,at+6);
    header.writeUInt32LE(buffer.length,at+8); header.writeUInt32LE(offset,at+12);
    offset += buffer.length;
  });
  fs.writeFileSync(path.join(root,'windows/runner/resources/app_icon.ico'),Buffer.concat([header,...images]));
  console.log('Generated Android, Windows, iOS, macOS and in-app icons from oplayer.svg');
})().catch(error=>{console.error(error);process.exitCode=1;});
