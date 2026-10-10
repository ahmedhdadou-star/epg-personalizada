'use strict'
const axios = require('axios')
const cheerio = require('cheerio')
const fs = require('fs')
const dayjs = require('dayjs')
dayjs.extend(require('dayjs/plugin/utc'))
dayjs.extend(require('dayjs/plugin/timezone'))
dayjs.extend(require('dayjs/plugin/customParseFormat'))

const ZONE = 'Africa/Casablanca'
const ID = '2M.ma'
const clean = value => String(value ?? '').replace(/\s+/g, ' ').trim()
const esc = value => String(value ?? '').replace(/[<>&"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&apos;' })[c])
const xmlTime = date => date.utc().format('YYYYMMDDHHmmss +0000')
const today = dayjs().tz(ZONE).format('YYYY-MM-DD')
const dates = Array.from({length:3}, (_, i) => dayjs(today).add(i, 'day').format('YYYY-MM-DD'))

async function fetchDate(fecha) {
  const {data} = await axios.get(`https://www.communesmaroc.com/fr/tv-programs/2m?dt=${fecha}`, {
    headers: {'User-Agent':'Mozilla/5.0'}, timeout:25000
  })
  const $ = cheerio.load(data)
  const result = []
  $('h6').each((_, node) => {
    const titulo = clean($(node).text())
    const container = $(node).closest('.info-box').parent()
    const hora = clean(container.find('.time-box span').first().text())
    if (!titulo || !/^\d{1,2}:\d{2}$/.test(hora)) return
    const inicio = dayjs.tz(`${fecha} ${hora}`, 'YYYY-MM-DD H:mm', ZONE)
    if (inicio.isValid() && inicio.format('YYYY-MM-DD') === fecha) {
      result.push({fecha, hora, titulo, inicio})
    }
  })
  return result
}

async function main() {
  let all = []
  for (const fecha of dates) {
    const list = await fetchDate(fecha)
    console.log(fecha, 'programas:', list.length)
    if (list.length < 10) throw new Error('Parrilla insuficiente para ' + fecha)
    all.push(...list)
    await new Promise(resolve => setTimeout(resolve, 600))
  }
  all.sort((a, b) => a.inicio.valueOf() - b.inicio.valueOf())
  const starts = new Set()
  const unique = []
  for (const p of all) {
    if (starts.has(p.inicio.valueOf())) continue
    starts.add(p.inicio.valueOf())
    unique.push(p)
  }
  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="2M Personal">\n'
  xml += `<channel id="${ID}"><display-name>2M Maroc</display-name></channel>\n`
  let noStop = 0
  for (let i = 0; i < unique.length; i++) {
    const p = unique[i], next = unique[i + 1]
    const minutes = next ? next.inicio.diff(p.inicio, 'minute') : -1
    const stop = minutes > 0 && minutes <= 300 ? ` stop="${xmlTime(next.inicio)}"` : ''
    if (!stop) noStop++
    xml += `<programme start="${xmlTime(p.inicio)}"${stop} channel="${ID}"><title>${esc(p.titulo)}</title></programme>\n`
  }
  xml += '</tv>\n'
  fs.writeFileSync('2m.xml', xml, 'utf8')
  console.log('2M:', unique.length, 'programas;', noStop, 'sin final')
}
main().catch(error => { console.error(error); process.exitCode = 1 })
