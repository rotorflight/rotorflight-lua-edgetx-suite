/** Generate independent golden vectors by executing the pinned upstream pure
 * helpers. Maintainer tool only: neither builds nor the radio read this source.
 * Usage: node bin/wizard/source_contracts.mjs <Configurator snapshot>/src <output.lua>
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
const [root,out]=process.argv.slice(2);
if(!root||!out) throw new Error('Expected source directory and output Lua file');
const hashes={};
function source(name){
  const text=fs.readFileSync(path.join(root,name),'utf8');
  hashes[name]=crypto.createHash('sha256').update(text).digest('hex');
  return text.replace(/^import[\s\S]*?;\r?\n/gm,'').replace(/\bexport\s+/g,'');
}
const context=vm.createContext({Mixer:{TAIL_MODE_VARIABLE:0},RATES_TYPE:{ROTORFLIGHT:6,ACTUAL:4},SWASH_LAYOUTS:{},TAIL_SERVO:3});
vm.runInContext(source('tabs/setup_wizard/heli.js')+'\nglobalThis.heli={calibratedRate,movedChannel,rangeForSwitch,collectiveAtFullStick,setCollectiveAtFullStick};',context);
vm.runInContext(source('tabs/setup_wizard/adjust.js')+'\nglobalThis.adjust={mappedRange,knobRange,steppedGainRange,mappedValue,profileMode,buttonAt};',context);
// rates.js imports functions already declared in the same test context.
vm.runInContext(source('tabs/setup_wizard/rates.js')+'\nglobalThis.rate={applyStyle,matchingStyle};',context);
const {heli,adjust,rate}=context;
const cases=[];
function add(fn,args,expected){cases.push({fn,args,expected:expected??null});}
for(const rate of [-1500,-1000,250,1000,2000]) for(const measurement of [1,4.5,9,18,30]) add('calibrated',[rate,measurement],heli.calibratedRate(rate,9,measurement));
for(const peaks of [ [],[0,0],[299,0],[300,150],[300,151],[500,0,100],[500,500],[120,10],[250,124]]) for(const minimum of [100,250,300]){
 const n=heli.movedChannel(peaks,[],minimum);add('moved',[peaks,null,minimum],n<0?null:n+1);
}
for(const a of [1000,1500,2000]) for(const b of [1000,1500,2000]){const r=heli.rangeForSwitch(a,b);add('switchRange',[a,b],[r.start,r.end]);}
for(const channel of [0,2,5]) for(const fn of [83,84]) for(const buttons of [false,true]) add('gain',[fn,channel,buttons],buttons?adjust.steppedGainRange(fn,channel):adjust.knobRange(fn,channel));
for(const low of [800,976,1000,1500]) for(const high of [1500,2024,2200]) add('mapped',[2,0,low,high,1,3],adjust.mappedRange(2,0,low,high,1,3));
const mapped=adjust.mappedRange(2,1,1000,2000,1,3);
for(const value of [500,999,1000,1249,1250,1500,1750,2000,2500]) add('mappedValue',[mapped,value],adjust.mappedValue(mapped,value));
for(const ratesType of [6,4,0]) for(const raw of [0,50,99,100,101,200]){
 const t={rates_type:ratesType,collective_rc_rate:raw/100,collective_srate:100/100};
 add('collective',[{rates_type:ratesType,rcRates_4:raw,rates_4:100}],heli.collectiveAtFullStick(t));
}
const styles=[{cyclic:180,yaw:270,expo:{cyclic:40,yaw:50}},{cyclic:250,yaw:400,expo:{cyclic:40,yaw:50}},{cyclic:400,yaw:600,expo:{cyclic:30,yaw:40}}];
function luaTuning(t){const o={rates_type:t.rates_type};for(const [n,a] of ['roll','pitch','yaw','collective'].entries()) for(const [src,dst] of [ ['rc_rate','rcRates_'],['srate','rates_'],['rc_expo','rcExpo_']]) o[dst+(n+1)]=Math.round(t[a+'_'+src]*100);return o;}
for(const type of [4,6]) for(const initial of [4,6,0]) for(let i=0;i<3;i++){
 const t={rates_type:initial};
 for(const axis of ['roll','pitch','yaw','collective']){t[axis+'_rc_rate']=1;t[axis+'_srate']=0.8;t[axis+'_rc_expo']=0.3;}
 const before=luaTuning(t);rate.applyStyle(t,styles[i],type);add('style',[before,i+1,type],luaTuning(t));
}
function lua(value){if(value===null||value===undefined)return 'nil';if(typeof value==='string')return JSON.stringify(value);if(typeof value==='number'||typeof value==='boolean')return String(value);if(Array.isArray(value))return '{'+value.map(lua).join(',')+'}';return '{'+Object.entries(value).map(([k,v])=>'['+JSON.stringify(k)+']='+lua(v)).join(',')+'}';}
fs.writeFileSync(out,'-- Generated from Configurator PR 491, commit 4a57ba971d7ffef06f39bb66b3f376d150a27e25.\n-- Pure upstream helpers produced these expectations; do not hand-edit them.\nreturn '+lua({hashes,cases})+'\n');
console.log(JSON.stringify({vectors:cases.length,sourceHashes:hashes}));
