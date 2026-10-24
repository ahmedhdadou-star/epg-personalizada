const axios = require('axios')
const cheerio = require('cheerio')
const fs = require('fs')
const dayjs = require('dayjs')

dayjs.extend(require('dayjs/plugin/utc'))
dayjs.extend(require('dayjs/plugin/timezone'))
dayjs.extend(require('dayjs/plugin/customParseFormat'))

// Zona provisional configurable hasta cotejar los horarios reales con emisiones.
// Confirmado con MBC 5 y Rotana Cinema Masr: los horarios web corresponden a Espana.
const ZONE = 'Europe/Madrid'
const YEAR = 2026

const ids = new Set([
  // beIN Movies, Series y Drama
  '1309','1322','1323','1324','1327','1328',

  // Egipto
  '1198','1199','1260','1290','1292',
  '1203','1134','1156','1159','1193','1223',

  // Emiratos
  '1169','1173','1283','1136',
  '1135','1177','1188','1266',

  // Magreb
  '1315','1308','1334','1304',

  // Otros canales árabes
  '1321','1216','1168','1296','1382','1261'
])

const catalogo = cheerio.load(
  fs.readFileSync('elcinema-todos.channels.xml', 'utf8'),
  { xmlMode: true }
)

const canales = catalogo('channel').toArray()
  .filter(el => ids.has(catalogo(el).attr('site_id')))
  .map(el => [
    catalogo(el).attr('site_id'),
    catalogo(el).attr('xmltv_id'),
    catalogo(el).text().trim()
  ])

console.log('Canales seleccionados:', canales.length)
const meses = {
  'يناير':1,'فبراير':2,'مارس':3,
  'ابريل':4,'أبريل':4,'مايو':5,
  'يونيو':6,'يوليو':7,
  'اغسطس':8,'أغسطس':8,'سبتمبر':9,
  'اكتوبر':10,'أكتوبر':10,
  'نوفمبر':11,'ديسمبر':12
}

const clean = s => String(s || '').replace(/\s+/g,' ').trim()

const esc = s => String(s ?? '').replace(/[<>&"']/g, c => ({
  '&':'&amp;', '<':'&lt;', '>':'&gt;',
  '"':'&quot;', "'":'&apos;'
})[c])

const xmlTime = d => d.utc().format('YYYYMMDDHHmmss +0000')

function fechaLocal(fecha, horario) {
  const f = clean(fecha).match(/(\d{1,2})\s+([^\s]+)/u)
  const h = clean(horario).match(
    /(\d{1,2}):(\d{2})\s*(صباحًا|مساءً)/u
  )

  if (!f || !meses[f[2]] || !h) return null

  const dia = String(f[1]).padStart(2,'0')
  const mes = String(meses[f[2]]).padStart(2,'0')
  const ampm = h[3] === 'مساءً' ? 'PM' : 'AM'

  const inicio = dayjs.tz(
    `${YEAR}-${mes}-${dia} ${h[1]}:${h[2]} ${ampm}`,
    'YYYY-MM-DD h:mm A',
    ZONE
  )

  return inicio.isValid() ? inicio : null
}

async function extraer([siteId, id, nombre]) {
  const url = `https://elcinema.com/tvguide/${siteId}/`

  const { data } = await axios.get(url, {
    headers: {'User-Agent':'Mozilla/5.0'},
    timeout: 20000
  })

  const $ = cheerio.load(data)
  const lista = []

  $('.dates').each((_, encabezado) => {
    const fecha = clean($(encabezado).text())
    const bloque = $(encabezado).parent().next()

    bloque.find('.padded-half').each((_, elemento) => {
      const p = $(elemento)

      const titulo = clean(
        p.find('.row > div.columns.small-6.large-3 > ul > li:nth-child(1) > a').text() ||
        p.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(1)').text()
      )

      const horario = clean(
        p.find('.row > div.columns.small-3.large-2 > ul > li:nth-child(1)').text() ||
        p.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(2)').text()
      )

      const duracionTexto = clean(
        p.find('.row > div.columns.small-3.large-2 > ul > li:nth-child(2) > span').text() ||
        p.find('.row > div.columns.small-7.large-11 > ul > li:nth-child(2) > span').text()
      )

      const duracion = Number(
        duracionTexto.replace(/\D/g,'')
      ) || null

      const descripcion = clean(
        p.find('.row > div.columns.small-12.large-6 > ul > li:nth-child(3)').text()
      ).replace(/\.{3}(اقرأ المزيد|Read more)/g,'').trim()

      const categoria = clean(
        p.find('.row > div.columns.small-6.large-3 > ul > li:nth-child(2)').text()
      ).replace(/\(\d+\)/g,'').trim()

      const inicio = fechaLocal(fecha, horario)

      if (!inicio || !titulo) return

      lista.push({
        id, nombre, titulo,
        descripcion, categoria,
        fecha, horario, duracion,
        inicio
      })
    })
  })

  return lista
}

async function main() {
  let todos = []
  const errores = []

  for (const canal of canales) {
    try {
      const lista = await extraer(canal)
      todos.push(...lista)
      console.log(`${canal[2]}: ${lista.length} programas`)
    } catch (e) {
      console.log(`${canal[2]}: ERROR ${e.message}`)
      errores.push({canal:canal[2],error:e.message})
    }

    // Peticiones secuenciales, con pequeña pausa
    await new Promise(r => setTimeout(r,700))
  }

  console.log('ELCINEMA_TIMEZONE:', ZONE, '(sin ajustes horarios artificiales)')
  console.log('Muestras ElCinema: fecha y hora web -> UTC XMLTV')
  for (const p of todos.slice(0, 12)) {
    console.log(`${p.nombre} | ${p.fecha} ${p.horario} -> ${xmlTime(p.inicio)}`)
  }

  todos.sort((a,b) =>
    a.id.localeCompare(b.id) ||
    a.inicio.valueOf()-b.inicio.valueOf()
  )

  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
  xml += '<tv generator-info-name="ElCinema Web Personal">\n'

  for (const [,id,nombre] of canales) {
    xml += `<channel id="${esc(id)}">`
    xml += `<display-name>${esc(nombre)}</display-name>`
    xml += '</channel>\n'
  }

  let exportados = 0, duplicados = 0, sinFin = 0
  const claves = new Set()

  for (let i=0; i<todos.length; i++) {
    const p = todos[i]
    const siguiente = todos[i+1]

    const clave = `${p.id}|${p.inicio.valueOf()}|${p.titulo}`

    if (claves.has(clave)) {
      duplicados++
      continue
    }
    claves.add(clave)

    let fin = null

    if (p.duracion > 0) {
      fin = p.inicio.add(p.duracion,'minute')
    } else if (siguiente &&
               siguiente.id === p.id &&
               siguiente.inicio.isAfter(p.inicio)) {
      fin = siguiente.inicio
    }

    if (!fin || !fin.isAfter(p.inicio)) {
      sinFin++
      continue
    }

    // Diagnostico: sin desplazamiento horario artificial; preservar tiempos interpretados.
    // Correccion contrastada con la emision: EPG publicada 6 horas atrasada.
    // Aplicar +6h una sola vez a inicio y fin, solo en ElCinema.
    const inicioXml = p.inicio.add(6, 'hour')
    const finXml = fin.add(6, 'hour')
    xml += `<programme start="${xmlTime(inicioXml)}"`
    xml += ` stop="${xmlTime(finXml)}"`
    xml += ` channel="${esc(p.id)}">\n`
    xml += `<title lang="ar">${esc(p.titulo)}</title>\n`

    if (p.descripcion) {
      xml += `<desc lang="ar">${esc(p.descripcion)}</desc>\n`
    }

    if (p.categoria) {
      xml += `<category lang="ar">${esc(p.categoria)}</category>\n`
    }

    xml += '</programme>\n'
    exportados++
  }

  xml += '</tv>\n'

  fs.writeFileSync('elcinema-otros-ar.xml',xml,'utf8')

  fs.writeFileSync(
    'elcinema-otros-ar.json',
    JSON.stringify(todos.map(p => ({
      ...p,
      inicio:p.inicio.format()
    })),null,2),
    'utf8'
  )

  console.log('\n===== RESUMEN =====')
  console.log('Programas encontrados:',todos.length)
  console.log('Programas XMLTV:',exportados)
  console.log('Duplicados:',duplicados)
  console.log('Sin fin válido:',sinFin)
  console.log('Errores HTTP:',errores.length)
  if (errores.length) console.log(errores)
}

main().catch(console.error)

