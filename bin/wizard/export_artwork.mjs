import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ART = path.join(ROOT, "artwork/helicopter_setup");
const GFX = path.join(ROOT, "src/rfsuite/app/pages/helicopter_setup/gfx");
const require = createRequire(path.join(ART, "package.json"));
const { compile, preprocess } = require("svelte/compiler");
const sass = require("sass");
const { Resvg } = require("@resvg/resvg-js");
const { render } = await import(pathToFileURL(require.resolve("svelte/server")));
const CHECK = process.argv.includes("--check");
const hash = data => createHash("sha256").update(data).digest("hex");
const readJson = async name => JSON.parse(await fs.readFile(path.join(ART, name), "utf8"));
const provenance = await readJson("provenance.json");
const catalog = await readJson("catalog.json");
const [W,H] = catalog.frame;
const cache = path.join(ART, ".cache");
await fs.mkdir(cache, { recursive: true });
let writes = 0;
async function emit(filename, bytes) {
  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes, "utf8");
  if (CHECK) {
    assert.deepEqual(await fs.readFile(filename), buffer, "Stale export: " + path.relative(ROOT, filename));
  } else {
    await fs.mkdir(path.dirname(filename), { recursive: true });
    await fs.writeFile(filename, buffer);
  }
  writes++;
  return { sha256: hash(buffer), bytes: buffer.length };
}
function validSource(buffer, expected) { return hash(buffer) === expected; }
const imported = provenance.files.filter(entry => entry.status === "imported");
for (const entry of provenance.files.filter(entry => entry.file)) {
  const buffer = await fs.readFile(path.join(ART, entry.file));
  assert(validSource(buffer, entry.sha256), "Changed upstream snapshot: " + entry.file);
  const corrupt = Buffer.from(buffer);
  corrupt[0] ^= 1;
  assert(!validSource(corrupt, entry.sha256), "Source corruption control failed");
}
assert.equal(imported.length, 15);
assert(!imported.some(entry => entry.path.endsWith("/HeliSide.svelte")));
assert.equal(new Set(catalog.exports.map(entry => entry.name)).size, catalog.exports.length);
const components = new Set(catalog.exports.map(entry => entry.component + ".svelte"));
assert.deepEqual([...components].sort(), imported.map(entry => path.basename(entry.file)).sort());

await fs.writeFile(path.join(cache, "i18n.mjs"),
  'export const i18n={subscribe(run){run({t:key=>key});return ()=>{};}};\n');
await fs.writeFile(path.join(cache, "mixer.mjs"),
  'export const Mixer={SWASH_TYPE_THRU:1,SWASH_TYPE_120:2,SWASH_TYPE_135:3,SWASH_TYPE_140:4,SWASH_TYPE_90L:5,SWASH_TYPE_90V:6};\n');
const swash = (await fs.readFile(path.join(ART,"upstream/swash.js"),"utf8"))
  .replace('"@/js/Mixer.js"', '"./mixer.mjs"');
assert(!swash.includes("@/"));
await fs.writeFile(path.join(cache,"swash.mjs"),swash);
const compiled = new Map();
for (const name of components) {
  let source = await fs.readFile(path.join(ART,"upstream",name),"utf8");
  source = source.replaceAll('"@/js/i18n.js"','"./i18n.mjs"')
    .replaceAll('"@/js/swash.js"','"./swash.mjs"');
  // Keep the vendored snapshot byte-exact; repair this malformed numeric unit only in exports.
  source = source.replace(/\uFFFD(?=\/s)/g, "°");
  assert(!source.includes("@/"), "Unmapped component import: "+name);
  const prepared = await preprocess(source, {style:({content}) => ({code:sass.compileString(content).css})});
  const result = compile(prepared.code, {
    filename:"artwork/helicopter_setup/upstream/"+name,
    generate:"server",css:"external",dev:false,
    cssHash:({css})=>"art-"+hash(css).slice(0,10)
  });
  const modulePath = path.join(cache,name.replace(".svelte",".mjs"));
  await fs.writeFile(modulePath,result.js.code);
  const module = await import(pathToFileURL(modulePath));
  compiled.set(name,{component:module.default,css:result.css?.code || ""});
}
function hsl(h,s,l) {
  const a=s*Math.min(l,1-l);
  const f=n=>{const k=(n+h/30)%12;return Math.round(255*(l-a*Math.max(-1,Math.min(k-3,9-k,1))));};
  return [f(0),f(8),f(4)];
}
const color=(h,s,l)=>"#"+hsl(h,s,l).map(v=>v.toString(16).padStart(2,"0")).join("");
function palette(dark) {
  const accent=color(203,dark ? 0.82 : 1,dark ? 0.58 : 0.39);
  const rgb=hsl(203,dark ? 0.82 : 1,dark ? 0.58 : 0.39);
  const neutral=l=>color(208,.09,l);
  return {
    "--color-accent-500":accent,
    "--color-accent-soft":"rgba("+rgb.join(",")+","+(dark?".16":".1")+")",
    "--color-surface":neutral(dark ? 0.11 : 1),
    "--color-surface-sunken":neutral(dark ? 0.07 : 0.98),
    "--color-text":neutral(dark ? 0.96 : 0.08),
    "--color-text-muted":neutral(dark ? 0.70 : 0.36),
    "--color-text-soft":neutral(dark ? 0.90 : 0.22),
    "--color-border":neutral(dark ? 0.22 : 0.76),
    "--color-border-soft":neutral(dark ? 0.22 : 0.90),
    "--color-status-good":"#56ac1d"
  };
}
function resolvedCss(css, colors) {
  let result=css.replace(/var\((--[\w-]+)\)/g,(_,key)=>{
    assert(key in colors,"Missing palette color: "+key);return colors[key];
  });
  result=result.replace(/color-mix\(in srgb,\s*(#[0-9a-f]{6})\s+([\d.]+)%,\s*transparent\)/gi,
    (_,hex,amount)=>"rgba("+[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)).join(",")+","+Number(amount)/100+")");
  // Browser layout declarations must not override the explicit SVG export dimensions.
  return result.replace(/(?<![-\w])(?:display|width|height|max-width|flex|overflow)\s*:[^;{}]+;/g,"");
}
function svgDocument(markup, css, colors, padding = 0) {
  const view=markup.match(/\bviewBox="([^"]+)"/);
  assert(view,"SVG has no viewBox");
  let [x,y,vw,vh]=view[1].split(/\s+/).map(Number);
  x-=padding; y-=padding; vw+=2*padding; vh+=2*padding;
  assert([x,y,vw,vh].every(Number.isFinite)&&vw>0&&vh>0);
  const scale=Math.min((W-12)/vw,(H-12)/vh);
  const tx=(W-vw*scale)/2-x*scale;
  const ty=(H-vh*scale)/2-y*scale;
  const body=markup.replace(/^<svg\b[^>]*>/,"").replace(/<\/svg>$/,"");
  const rootClass=markup.match(/\bclass="([^"]*)"/)?.[1] || "";
  return '<svg xmlns="http://www.w3.org/2000/svg" width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'" color="'+colors["--color-text-muted"]+'" font-family="Arial, sans-serif">\n'
    +'<style>'+resolvedCss(css,colors)+'</style>\n'
    +'<g transform="translate('+tx+' '+ty+') scale('+scale+')"><g class="'+rootClass+'">'+body+'</g></g>\n</svg>\n';
}
const records=[];
for (const item of catalog.exports) {
  assert(/^[a-z0-9-]+$/.test(item.name));
  const entry=compiled.get(item.component+".svelte");
  const rendered=render(entry.component,{props:item.props});
  const svgs=[...rendered.body.matchAll(/<svg\b[\s\S]*?<\/svg>/g)].map(match=>match[0]);
  assert(svgs[item.index],"Missing SVG variant: "+item.name);
  let markup=svgs[item.index];
  let css=entry.css;
  if (item.leverAngle !== undefined) {
    assert.equal(item.component,"SwitchFlick");
    assert([-28,28].includes(item.leverAngle));
    const lever=/<g\b[^>]*class="[^"]*\blever\b[^"]*"[^>]*>/g;
    assert.equal([...markup.matchAll(lever)].length,1);
    markup=markup.replace(lever,tag=>tag.slice(0,-1)+' transform="rotate('+item.leverAngle+' 20 36)">');
    // Freeze the source keyframe geometrically; CSS transforms are not portable SVG poses.
    css=css.replace(/(?:animation|transform-origin|transform)\s*:[^;{}]+[;]?/g,"");
  }
  for (const theme of ["light","dark"]) {
    const colors=palette(theme==="dark");
    const svg=svgDocument(markup,css,colors,item.viewPadding || 0).split("\n").map(line=>line.trimEnd()).join("\n");
    assert(!/\b(?:NaN|Infinity)\b|\bvar\(/.test(svg), "Unresolved SVG values");
    const svgFile=path.join(ART,"svg",theme,item.name+".svg");
    const svgInfo=await emit(svgFile,svg);
    const raster=new Resvg(svg,{font:{loadSystemFonts:true,defaultFontFamily:"Arial"}}).render();
    assert.equal(raster.width,W);assert.equal(raster.height,H);
    const pngInfo=await emit(path.join(GFX,theme,item.name+".png"),raster.asPng());
    records.push({name:item.name,theme,component:item.component,props:item.props,index:item.index,leverAngle:item.leverAngle,viewPadding:item.viewPadding,svg:svgInfo,png:pngInfo});
  }
}
for (const theme of ["light","dark"]) {
  const left=records.find(item=>item.name==="switch-left" && item.theme===theme);
  const right=records.find(item=>item.name==="switch-right" && item.theme===theme);
  assert.notEqual(left.png.sha256,right.png.sha256,"Switch poses rendered identically");
}
const acceptedChecks=await readJson("heli/checks.json");
const sourceNames={"heli-remove-blades":"accepted/heli-remove-blades.png","heli-level":"accepted/heli-level.png","heli-tail-lift":"accepted/heli-tail-lift.png"};
for (const name of catalog.custom) {
  const data=await fs.readFile(path.join(ART,"heli/accepted",name+".png"));
  const expected=acceptedChecks.outputs.find(entry=>entry.name===sourceNames[name]);
  assert(expected && validSource(data,expected.sha256),"Accepted helicopter source changed: "+name);
  const svg='<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="'+W+'" height="'+H+'"><image x="0" y="25" width="'+W+'" height="110" xlink:href="data:image/png;base64,'+data.toString("base64")+'"/></svg>';
  const raster=new Resvg(svg).render();
  const pngInfo=await emit(path.join(GFX,name+".png"),raster.asPng());
  records.push({name,sourceSha256:hash(data),png:pngInfo});
}
const manifest={schema:1,sourceCommit:provenance.commit,frame:catalog.frame,font:"Arial (system font)",svgComponents:imported.length,variants:catalog.exports.length,svgExports:catalog.exports.length*2,customHelicopters:catalog.custom.length,exports:records};
await emit(path.join(ART,"exports.json"),JSON.stringify(manifest,null,2)+"\n");
console.log(JSON.stringify({mode:CHECK?"checked":"exported",components:imported.length,variants:catalog.exports.length,svg:catalog.exports.length*2,png:records.length,files:writes,frame:catalog.frame,sourceCorruptionControls:provenance.files.filter(entry=>entry.file).length}));
