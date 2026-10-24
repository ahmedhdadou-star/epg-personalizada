'use strict'
// ElCinema limpio: solo la programación disponible en la página actual.
// Sin desplazamientos manuales, fechas anteriores, ni rellenos.
const fs = require('fs')
const axios = require('axios')
const cheerio = require('cheerio')
const dayjs = require('dayjs')
dayjs.extend(require('dayjs/plugin/utc'))
dayjs.extend(require('dayjs/plugin/timezone'))
dayjs.extend(require('dayjs/plugin/customParseFormat'))
const ZONE = 'Europe/Madrid'
const MONTHS = {'يناير':1,'فبراير':2,'مارس':3,'ابريل':4,'أبريل':4,'مايو':5,'يونيو':6,'يوليو':7,'اغسطس':8,'أغسطس':8,'سبتمبر':9,'اكتوبر':10,'أكتوبر':10,'نوفمبر':11,'ديسمبر':12}
const tidy = s => String(s || '').replace(/\s+/g,' ').trim()
const xmlEsc = s => String(s ?? '').replace(/[<>&"']/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]))
const utc = t => t.utc().format('YYYYMMDDHHmmss +0000')
const group = process.argv[2]
if (!['mbc-rotana','otros-ar'].includes(group)) throw new Error('Uso: node elcinema-grabber.cjs mbc-rotana|otros-ar')
const targets = new Set(fs.readFileSync('elcinema-objetivos.txt','utf8').replace(/^\uFEFF/,'').split(/\r?\n/).map(tidy).filter(Boolean))
const $catalog = cheerio.load(fs.readFileSync('elcinema-todos.channels.xml','utf8'), {xmlMode:true})
const catalog = $catalog('channel').toArray().map(el => ({
  id: $catalog(el).attr('xmltv_id'), site: $catalog(el).attr('site_id'), name: tidy($catalog(el).text())
}))
// El catálogo histórico etiqueta este canal como elcinema-1135.
const alias = {'EmiratesTV.ae':'1135'}
const channels = [...targets].map(id => {
  const match = catalog.find(c => c.id === id || (alias[id] && c.site === alias[id]))
  if (!match) throw new Error('Falta canal en catálogo: ' + id)
  return {...match,id}
}).filter(c => (c.id.startsWith('MBC') || c.id.startsWith('Rotana')) === (group === 'mbc-rotana'))
if (!channels.length) throw new Error('Sin canales para ' + group)
function parsedDate(dateText, timeText) {
  const date = tidy(dateText).match(/(\d{1,2})\s+([^\s]+)/u)
  const time = tidy(timeText).match(/(\d{1,2}):(\d{2})\s*(صباحًا|مساءً)/u)
  if (!date || !MONTHS[date[2]] || !time) return null
  const month = String(MONTHS[date[2]]).padStart(2,'0'), day = date[1].padStart(2,'0')
  const hour = Number(time[1]) % 12 + (time[3] === 'مساءً' ? 12 : 0)
  // Deducir el año del bloque de fechas más próximo a la fecha actual.
  const today = dayjs().tz(ZONE)
  const choices = [today.year()-1,today.year(),today.year()+1].map(year =>
    dayjs.tz(year+'-'+month+'-'+day+' '+String(hour).padStart(2,'0')+':'+time[2], 'YYYY-MM-DD HH:mm',ZONE))
  const result = choices.filter(x => x.isValid()).sort((a,b) =>
    Math.abs(a.diff(today)) - Math.abs(b.diff(today)))[0]
  return result || null
}
function showsFrom(html, channel) {
  const $ = cheerio.load(html), shows = [], seen = new Set()
  $('.dates').each((_,header) => {
    const date = tidy($(header).text())
    $(header).parent().next().find('.padded-half').each((_,elem) => {
      const card = $(elem)
      const title = tidy(card.find('.row > div.columns.small-6.large-3 > ul > li:nth-child(1) > a').text()
        || card.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(1)').text())
      const time = tidy(card.find('.row > div.columns.small-3.large-2 > ul > li:nth-child(1)').text()
        || card.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(2)').text())
      const durationText = tidy(card.find('.row > div.columns.small-3.large-2 > ul > li:nth-child(2) > span').text()
        || card.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(2) > span').text())
      const duration = Number(durationText.replace(/\D/g,'')) || null
      const description = tidy(card.find('.row > div.columns.small-12.large-6 > ul > li:nth-child(3)').text())
        .replace(/\.{3}(اقرأ المزيد|Read more)/gu,'').trim()
      const category = tidy(card.find('.row > div.columns.small-6.large-3 > ul > li:nth-child(2)').text())
        .replace(/\(\d+\)/g,'').trim()
      const start = parsedDate(date,time)
      if (!title || !start) return
      const key = start.valueOf()+'|'+title
      if (seen.has(key)) return
      seen.add(key)
      shows.push({id:channel.id,nombre:channel.name,fecha:date,horario:time,titulo:title,
        descripcion:description,categoria:category,duracion:duration,inicio:start})
    })
  })
  return shows.sort((a,b)=>a.inicio.valueOf()-b.inicio.valueOf())
}
async function main() {
  const raw = [], errors = []
  for (const c of channels) {
    try {
      const response = await axios.get('https://elcinema.com/tvguide/'+c.site+'/',{
        timeout:25000, headers:{'User-Agent':'Mozilla/5.0 (compatible; XMLTV-Guide/1.0)','Accept-Language':'ar,en;q=0.8'}
      })
      const rows = showsFrom(response.data,c)
      raw.push(...rows)
      console.log(c.id+': '+rows.length+' emisiones, primera '+(rows[0] ? rows[0].inicio.format() : 'ninguna'))
    } catch(e) {errors.push(c.id+': '+e.message);console.warn(errors[errors.length-1])}
    await new Promise(resolve => setTimeout(resolve,500))
  }
  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="ElCinema limpio">\n'
  for (const c of channels) xml += '<channel id="'+xmlEsc(c.id)+'"><display-name>'+xmlEsc(c.name)+'</display-name></channel>\n'
  let count=0, skipped=0
  for (const c of channels) {
    const events=raw.filter(p=>p.id===c.id)
    for(let i=0;i<events.length;i++) {
      const p=events[i], next=events[i+1]
      const end=p.duracion ? p.inicio.add(p.duracion,'minute') : (next ? next.inicio : null)
      if(!end || !end.isAfter(p.inicio)) {skipped++;continue}
      xml += '<programme start="'+utc(p.inicio)+'" stop="'+utc(end)+'" channel="'+xmlEsc(p.id)+'">\n'
        +'<title lang="ar">'+xmlEsc(p.titulo)+'</title>\n'
      if(p.descripcion) xml += '<desc lang="ar">'+xmlEsc(p.descripcion)+'</desc>\n'
      if(p.categoria) xml += '<category lang="ar">'+xmlEsc(p.categoria)+'</category>\n'
      xml += '</programme>\n';count++
    }
  }
  xml += '</tv>\n'
  const file='elcinema-'+group
  fs.writeFileSync(file+'.xml',xml,'utf8')
  fs.writeFileSync(file+'.json',JSON.stringify(raw.map(p=>({...p,inicio:p.inicio.format()})),null,2),'utf8')
  console.log('RESULTADO '+file+': '+count+' programas XMLTV, '+skipped+' sin fin, '+errors.length+' errores. Zona '+ZONE+'; desplazamiento manual 0h.')
  if (!count) throw new Error('ElCinema no devolvió ningún programa; no debe publicarse como válido')
}
main().catch(e=>{console.error(e);process.exitCode=1})
