'use strict'
const fs=require('fs'), assert=require('node:assert/strict'), cheerio=require('cheerio')
const wanted=fs.readFileSync('elcinema-objetivos.txt','utf8').replace(/^\uFEFF/,'').trim().split(/\r?\n/).map(x=>x.trim()).filter(Boolean)
assert.equal(new Set(wanted).size,31,'La selección debe tener 31 canales únicos')
function xmlUtc(iso) {
 const d=new Date(iso)
 assert.ok(!Number.isNaN(d.getTime()),'Fecha inválida: '+iso)
 const s=d.toISOString().replace(/[-:]/g,'').slice(0,14)
 return s+' +0000'
}
assert.equal(xmlUtc('2026-10-24T03:00:00+02:00'),'20261024010000 +0000')
let all=0, channels=new Set()
for(const base of ['elcinema-mbc-rotana','elcinema-otros-ar']) {
 const raw=JSON.parse(fs.readFileSync(base+'.json','utf8'))
 const $=cheerio.load(fs.readFileSync(base+'.xml','utf8'),{xmlMode:true})
 const defined=$('channel').toArray().map(x=>$(x).attr('id'))
 for(const id of defined){assert.ok(wanted.includes(id),'Canal no seleccionado: '+id); assert.ok(!channels.has(id),'ID duplicado: '+id);channels.add(id)}
 const expected=new Set(raw.map(p=>[p.id,xmlUtc(p.inicio),p.titulo].join('|')))
 let n=0
 $('programme').each((_,element)=>{
   const p=$(element), id=p.attr('channel'),start=p.attr('start'),stop=p.attr('stop'),title=p.find('title').first().text()
   assert.ok(channels.has(id),'Canal no definido '+id)
   assert.match(start,/^\d{14} \+0000$/)
   assert.match(stop,/^\d{14} \+0000$/)
   assert.ok(stop>start,'Fin no posterior al comienzo')
   assert.ok(expected.has([id,start,title].join('|')),'Horario XML distinto al JSON original: '+id+' '+start+' '+title)
   n++
 })
 assert.ok(n>0, 'Archivo sin programas: '+base)
 console.log(base+': '+defined.length+' canales, '+n+' programas comprobados contra los horarios originales')
 all+=n
}
assert.equal(channels.size,31,'Los dos grabbers deben cubrir exactamente 31 canales')
assert.ok(all>=31,'Muy pocos programas de ElCinema')
console.log('VERIFICACIÓN COMPLETA: 31 canales, '+all+' programas; sin desplazamiento')
