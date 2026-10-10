// EPG independiente MEDI1TV Arabic. Node.js, axios, cheerio, dayjs.
// Ejecución: node .\medi1-oficial.cjs
// Variables opcionales: MEDI1_DAYS=3 MEDI1_DATE=2026-10-06
const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const dayjs = require('dayjs');
dayjs.extend(require('dayjs/plugin/utc'));
dayjs.extend(require('dayjs/plugin/timezone'));
dayjs.extend(require('dayjs/plugin/customParseFormat'));

const ZONE = 'Africa/Casablanca';
const ID = 'Medi1TVArabic.ma';
const DAYS = Math.min(7, Math.max(1, Number(process.env.MEDI1_DAYS || 3)));
const START = process.env.MEDI1_DATE || dayjs().tz(ZONE).format('YYYY-MM-DD');
const clean = x => String(x || '').replace(/\s+/gu, ' ').trim();
const esc = x => String(x ?? '').replace(/[<>&"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const fmt = x => x.utc().format('YYYYMMDDHHmmss +0000');
const exactTime = /^(?:[01]?\d|2[0-3]):[0-5]\d$/;

const BROWSER_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
  'Accept-Language': 'ar-MA,ar;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5',
  'Cache-Control': 'no-cache',
  'Pragma': 'no-cache',
  'Upgrade-Insecure-Requests': '1',
  'Sec-Fetch-Dest': 'document',
  'Sec-Fetch-Mode': 'navigate',
  'Sec-Fetch-Site': 'same-origin',
  'Sec-Fetch-User': '?1'
};

function cookieString(setCookie = []) {
  return setCookie
    .map(v => String(v).split(';')[0])
    .filter(Boolean)
    .join('; ');
}

async function crearSesion() {
  const client = axios.create({
    timeout: 25000,
    maxRedirects: 5,
    validateStatus: s => s >= 200 && s < 400
  });

  const home = await client.get('https://www.medi1tv.com/ar', {
    headers: {
      ...BROWSER_HEADERS,
      'Referer': 'https://www.google.com/'
    }
  });

  const cookies = cookieString(home.headers['set-cookie']);

  return {
    client,
    cookies,
    async get(url) {
      return client.get(url, {
        headers: {
          ...BROWSER_HEADERS,
          'Referer': 'https://www.medi1tv.com/ar',
          ...(cookies ? { 'Cookie': cookies } : {})
        }
      });
    }
  };
}

const programSelectors = '.program, .programme, .schedule-item, .grille-item, .program-item, .programme-item, .program-block, .programme-block, .grille-program, .program-row, .programme-row, .item-program, .item-programme';
const titleSelectors = '.program-title, .programme-title, .title, .program-name, .programme-name, h2, h3, h4, h5, strong';
const descSelectors = '.program-description, .programme-description, .description, .desc, p';
function text(e, $) { return clean($(e).text()); }
function isTimeLeaf(el, $) { return $(el).children().length === 0 && exactTime.test(text(el,$)); }

function extract($) {
  const times = $('body *').filter((_, el) => isTimeLeaf(el, $)).toArray();
  const result = [];
  for (const el of times) {
    const t = text(el,$);
    let candidate = null;
    let ptr = $(el);
    for (let level=0; level<6 && ptr.length; level++,ptr=ptr.parent()) {
      const tag = (ptr[0]?.tagName || '').toLowerCase();
      if (/^(body|main|html|section|header|footer|nav)$/.test(tag)) break;
      const innerTimes = ptr.find('*').filter((_,e) => isTimeLeaf(e,$)).toArray();
      if (innerTimes.length !== 1) continue;
      const totalText = text(ptr, $);
      if (totalText.length < t.length+3 || totalText.length > 1300) continue;
      let title = '';
      ptr.find(titleSelectors).each((_,e)=>{
        const v = text(e,$);
        if (!title && v && v !== t && !exactTime.test(v) && v.length < 180) title=v;
      });
      if (!title) {
        const lines = ptr.text().split(/[\n\r]+/).map(clean).filter(Boolean);
        title = lines.find(x => x !== t && !exactTime.test(x) && x.length < 180) || '';
      }
      if (title && title!==t && !exactTime.test(title)) {
        let description='';
        ptr.find(descSelectors).each((_,e)=>{const v=text(e,$);if (!description && v!==title && v!==t && v.length>title.length && v.length>25 && v.length<900) description=v;});
        // Guardar el contenedor más cercano que contenga título identificable.
        candidate={hora:t,titulo:title,descripcion:description,clase:clean(ptr.attr('class')),nivel:level};
        break;
      }
    }
    if (candidate) result.push(candidate);
  }
  const dedup = new Map();
  for (const p of result) {
    if (!dedup.has(p.hora)) dedup.set(p.hora,p);
    else {
      // No decidir automáticamente entre dos emisiones simultáneas.
      const old=dedup.get(p.hora);
      if (old.titulo!==p.titulo) throw new Error(`Dos títulos para ${p.hora}: ${old.titulo} / ${p.titulo}`);
    }
  }
  return {data:[...dedup.values()],totalTimes:times.length};
}
async function main() {
  const session = await crearSesion();
  let all=[];
  for (let i=0;i<DAYS+1;i++) { // Día adicional para cierre de la última emisión
    const date=dayjs(START).add(i,'day').format('YYYY-MM-DD');
    const path=date.split('-').reverse().join('-');
    const url=`https://www.medi1tv.com/ar/grille/arabic/${path}`;
    const {data:html}=await session.get(url);
    const $=cheerio.load(html);
    const {data,totalTimes}=extract($);
    console.log(`${date}: ${data.length} emisiones reconocidas / ${totalTimes} horarios detectados`);
    console.log('  EJEMPLOS:',data.slice(0,4).map(p=>`${p.hora} ${p.titulo}`).join(' | '));
    if (data.length<12 || totalTimes<12 || data.length < Math.floor(totalTimes*.60)) {
      throw new Error(`Estructura no verificada el ${date}; no se modifica medi1-arabic.xml`);
    }
    for (const p of data) {
      const start=dayjs.tz(`${date} ${p.hora}`,'YYYY-MM-DD HH:mm',ZONE);
      if (!start.isValid() || start.format('YYYY-MM-DD HH:mm')!==`${date} ${p.hora}`) throw new Error(`Hora inválida: ${date} ${p.hora}`);
      all.push({...p,date,start});
    }
    await new Promise(resolve=>setTimeout(resolve,400));
  }
  all.sort((a,b)=>a.start.valueOf()-b.start.valueOf());
  let xml='<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="Medi1 oficial personal">\n';
  xml+=`<channel id="${ID}"><display-name>MEDI1TV Arabic</display-name></channel>\n`;
  let total=0,missingStop=0;
  for (let i=0;i<all.length;i++) {
    const p=all[i], next=all[i+1];
    if (p.date >= dayjs(START).add(DAYS,'day').format('YYYY-MM-DD')) continue; // día de cierre
    const minutes=next?next.start.diff(p.start,'minute'):0;
    const stop= minutes>0 && minutes<=480 ? ` stop="${fmt(next.start)}"` : '';
    if (!stop) missingStop++;
    xml+=`<programme start="${fmt(p.start)}"${stop} channel="${ID}"><title lang="ar">${esc(p.titulo)}</title>`;
    if (p.descripcion) xml+=`<desc lang="ar">${esc(p.descripcion)}</desc>`;
    xml+='</programme>\n'; total++;
  }
  xml+='</tv>\n';
  if (total < DAYS*12) throw new Error(`Cobertura insuficiente (${total}); se conserva XML anterior`);
  const temp='medi1-arabic.nuevo.xml';
  fs.writeFileSync(temp,xml,'utf8');
  // Valida XML con parseador disponible en iptv-org/epg si existe; si no, Cheerio XML.
  const doc=cheerio.load(fs.readFileSync(temp,'utf8'),{xmlMode:true});
  if (doc('programme').length!==total) throw new Error('XMLTV generado no supera la comprobación');
  fs.renameSync(temp,'medi1-arabic.xml');
  console.log(`OK: ${total} programas; ${missingStop} sin final. Archivo: medi1-arabic.xml`);
}
main().catch(e=>{console.error('ERROR:',e.message);process.exitCode=1});
