// Puts an .ico file's images in place of a Windows .exe's own icon (resource group 1), with
// no other tools: the new images are written over the old ones inside the resource section,
// so nothing moves. That only works while each new image fits in an old one's space, which
// it does for love.exe and windows/drakon.ico (PNG icons are much smaller than LÖVE's
// bitmaps); otherwise it says so and changes nothing.
// node tools/exeicon.js <exe> <ico>        (do it before appending the .love to love.exe)
'use strict';
const fs = require('fs');

const RT_ICON = 3, RT_GROUP_ICON = 14;

/** fail with a message (exit code 1) */
function fail(why) {
  console.error('exeicon: ' + why);
  process.exit(1);
}

const [exePath, icoPath] = process.argv.slice(2);
if (!exePath || !icoPath) fail('usage: node tools/exeicon.js <exe> <ico>');
const exe = fs.readFileSync(exePath);
const ico = fs.readFileSync(icoPath);

// --- the .ico: its images and their header fields
if (ico.readUInt16LE(0) !== 0 || ico.readUInt16LE(2) !== 1) fail(icoPath + ' is not an .ico file');
const images = [];
for (let i = 0; i < ico.readUInt16LE(4); i++) {
  const e = 6 + 16 * i;
  const size = ico.readUInt32LE(e + 8), offset = ico.readUInt32LE(e + 12);
  images.push({ header: ico.subarray(e, e + 12), data: ico.subarray(offset, offset + size) });
}

// --- the .exe: find the resource section
if (exe.toString('latin1', 0, 2) !== 'MZ') fail(exePath + ' is not a Windows program');
const pe = exe.readUInt32LE(0x3c);
const sections = exe.readUInt16LE(pe + 6), optSize = exe.readUInt16LE(pe + 20), opt = pe + 24;
const dirs = opt + (exe.readUInt16LE(opt) === 0x20b ? 112 : 96);   // 64- or 32-bit
const rsrcRva = exe.readUInt32LE(dirs + 16);
let rsrc = null;
for (let i = 0, s = opt + optSize; i < sections; i++, s += 40) {
  const va = exe.readUInt32LE(s + 12), rawSize = exe.readUInt32LE(s + 16), raw = exe.readUInt32LE(s + 20);
  if (rsrcRva >= va && rsrcRva < va + rawSize) rsrc = { va, raw, base: raw + (rsrcRva - va) };
}
if (!rsrc) fail(exePath + ' has no resources');
/** file offset of an address in the resource section */
const fileOffset = (rva) => rsrc.raw + (rva - rsrc.va);

/** entries of a resource directory: { id, offset (to a subdirectory or a data entry), isDir } */
function entries(dirOffset) {
  const out = [];
  const count = exe.readUInt16LE(dirOffset + 12) + exe.readUInt16LE(dirOffset + 14);
  for (let i = 0; i < count; i++) {
    const e = dirOffset + 16 + 8 * i;
    const id = exe.readUInt32LE(e), to = exe.readUInt32LE(e + 4);
    out.push({ id: id & 0x80000000 ? null : id, offset: rsrc.base + (to & 0x7fffffff), isDir: !!(to & 0x80000000) });
  }
  return out;
}
/** data entries of one resource type, by id: { [id]: data entry offset } (first language) */
function resources(type) {
  const t = entries(rsrc.base).find((e) => e.id === type && e.isDir);
  const out = {};
  if (t) for (const n of entries(t.offset)) {
    if (n.id === null || !n.isDir) continue;
    const lang = entries(n.offset).find((l) => !l.isDir);
    if (lang) out[n.id] = lang.offset;
  }
  return out;
}

const groups = resources(RT_GROUP_ICON), icons = resources(RT_ICON);
const groupEntry = groups[1] ?? groups[Object.keys(groups)[0]];
if (groupEntry === undefined) fail(exePath + ' has no icon');
const groupAt = fileOffset(exe.readUInt32LE(groupEntry)), groupSpace = exe.readUInt32LE(groupEntry + 4);

// the old icon images this group uses, and the space each has
const slots = [];
for (let i = 0; i < exe.readUInt16LE(groupAt + 4); i++) {
  const id = exe.readUInt16LE(groupAt + 6 + 14 * i + 12);
  if (icons[id] !== undefined) slots.push({ id, entry: icons[id], space: exe.readUInt32LE(icons[id] + 4) });
}
if (images.length > slots.length) fail(`the .ico has ${images.length} images but the program's icon only ${slots.length}`);
if (6 + 14 * images.length > groupSpace) fail('the icon group has no room');

// smallest image into the smallest space, and so on
const order = images.map((_, i) => i).sort((a, b) => images[a].data.length - images[b].data.length);
slots.sort((a, b) => a.space - b.space);
const plan = [];
let free = slots.slice();
for (const i of order) {
  const k = free.findIndex((s) => s.space >= images[i].data.length);
  if (k < 0) fail(`a ${images[i].data.length}-byte image doesn't fit in the program's icon`);
  plan[i] = free[k];
  free.splice(k, 1);
}

// write the images over the old ones, then the group that lists them
images.forEach((img, i) => {
  const slot = plan[i];
  const at = fileOffset(exe.readUInt32LE(slot.entry));
  exe.fill(0, at, at + slot.space);
  img.data.copy(exe, at);
  exe.writeUInt32LE(img.data.length, slot.entry + 4);
});
const group = Buffer.alloc(6 + 14 * images.length);
group.writeUInt16LE(0, 0);
group.writeUInt16LE(1, 2);
group.writeUInt16LE(images.length, 4);
images.forEach((img, i) => {
  img.header.copy(group, 6 + 14 * i);      // width, height, colours, planes, bit count, size
  group.writeUInt16LE(plan[i].id, 6 + 14 * i + 12);
});
exe.fill(0, groupAt, groupAt + groupSpace);
group.copy(exe, groupAt);
exe.writeUInt32LE(group.length, groupEntry + 4);
// leftover old images stay in the file, unused; a signature, if any, no longer matches
fs.writeFileSync(exePath, exe);
console.log(`exeicon: ${exePath} now has the ${images.length} icons of ${icoPath}`);
