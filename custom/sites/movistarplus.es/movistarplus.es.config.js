
const axios = require('axios')
const dayjs = require('dayjs')
const timezone = require('dayjs/plugin/timezone')
const utc = require('dayjs/plugin/utc')

dayjs.extend(utc)
dayjs.extend(timezone)
dayjs.tz.setDefault('Europe/Madrid')

module.exports = {
  site: 'movistarplus.es',
  days: 2,

  url({ channel, date }) {
    return `https://ottcache.dof6.com/movistarplus/webplayer/OTT/epg?from=${date.format('YYYY-MM-DDTHH:mm:ss')}&span=1&channel=${channel.site_id}&version=8&mdrm=true&tlsstream=true&demarcation=18`
  },

  request: {
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      Accept:
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
      Referer: 'https://www.movistarplus.es/programacion-tv'
    },
    maxRedirects: 5
  },

  async parser({ content }) {
    let programs = []
    let items = await parseItems(content)

    if (!items.length) return programs

    items.forEach(el => {
      programs.push({
        title: el.title,
        description: el.description,
        icon: el.icon,
        images: el.images,
        season: el.season,
        episode: el.episode,
        start: el.start,
        stop: el.stop
      })
    })

    return programs
  },

  async channels() {
    const json = await axios
      .get(
        'https://ottcache.dof6.com/movistarplus/webplayer/OTT/contents/channels?mdrm=true&tlsstream=true&demarcation=18&version=8'
      )
      .then(r => r.data)
      .catch(console.log)

    // Load JSON, CodCadenaTv is the closest
    // to the old MVSTR site channel ID.
    return json.map(channel => {
      return {
        lang: 'es',
        site_id: channel.CodCadenaTv,
        name: channel.Nombre,
        logo: channel.Logo ? channel.Logos[0].url : null
      }
    })
  }
}

// Extract programme images.
function parseImages(images) {
  return images
    .filter(image => image.id === 'watch2tgr-end')
    .map(image => image.uri)
}

// Build an improved programme title using
// the episode information when available.
function getTitle(json, fichaJson = {}) {
  const title = json?.Titulo || fichaJson?.Titulo || ''

  const episode =
    json?.TituloEpisodio ||
    fichaJson?.TituloEpisodio ||
    ''

  if (!episode) return title

  const cleanEpisode = String(episode)
    .replace(/^["']|["']$/g, '')
    .trim()

  if (!cleanEpisode || cleanEpisode === title) {
    return title
  }

  if (!title) return cleanEpisode

  return `${title}: ${cleanEpisode}`
}

// Parse Movistar Plus+ EPG.
async function parseItems(content) {
  try {
    const data = JSON.parse(content)

    const programs = Array.isArray(data)
      ? data
      : [data]

    return await Promise.all(
      programs.map(async json => {
        const start = dayjs.utc(
          Number(json?.FechaHoraInicio)
        )

        const stop = dayjs.utc(
          Number(json?.FechaHoraFin)
        )

        const ficha = json?.Ficha || null

        // Programme without an extended details page.
        if (!ficha) {
          return {
            title: getTitle(json),
            description: json?.Resena || '',
            icon: json?.Imagen || '',
            images: json.Imagenes
              ? parseImages(json.Imagenes)
              : [],
            start,
            stop
          }
        }

        // Programme with an extended details page.
        try {
          const fichaJson = await axios
            .get(ficha)
            .then(r => r.data)

          return {
            title: getTitle(json, fichaJson),
            description:
              fichaJson?.Descripcion ||
              json?.Resena ||
              '',
            icon: fichaJson?.Imagen || '',
            images: fichaJson.Imagenes
              ? parseImages(fichaJson.Imagenes)
              : [],
            actors: fichaJson?.Actores || [],
            directors: fichaJson?.Directores || [],
            classification:
              fichaJson?.Clasificacion || '',
            season: fichaJson?.Temporada || null,
            episode: fichaJson?.NumeroEpisodio || null,
            start,
            stop
          }

        } catch {
          // Fallback if extended details are unavailable.
          return {
            title: getTitle(json),
            description: json?.Resena || '',
            icon: json?.Imagen || '',
            images: json.Imagenes
              ? parseImages(json.Imagenes)
              : [],
            start,
            stop
          }
        }
      })
    )

  } catch {
    return []
  }
}
