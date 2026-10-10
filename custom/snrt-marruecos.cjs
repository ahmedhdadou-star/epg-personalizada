const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const dayjs = require('dayjs');

dayjs.extend(require('dayjs/plugin/utc'));
dayjs.extend(require('dayjs/plugin/timezone'));
dayjs.extend(require('dayjs/plugin/customParseFormat'));

const ZONE = 'Africa/Casablanca';

const canales = [
  ['1208', 'AlAoula.ma', 'Al Aoula'],
  ['4070', 'Arryadia.ma', 'Arryadia'],
  ['4071', 'Athaqafia.ma', 'Athaqafia'],
  ['4072', 'AlMaghribia.ma', 'Al Maghribia'],
  ['4073', 'Assadissa.ma', 'Assadissa'],
  ['4075', 'TamazightTV.ma', 'Tamazight TV']
];

const clean = s => String(s || '').replace(/\s+/g, ' ').trim();

const esc = s => String(s ?? '').replace(/[<>&"']/g,
  c => ({
    '&':'&amp;', '<':'&lt;', '>':'&gt;',
    '"':'&quot;', "'":'&apos;'
  }[c])
);

const xmlTime = d => d.utc().format('YYYYMMDDHHmmss +0000');

async function extraer([nodo, id, nombre]) {
  const url = `https://www.snrt.ma/ar/node/${nodo}`;

  const {data} = await axios.get(url, {
    headers: {'User-Agent':'Mozilla/5.0'},
    timeout: 20000
  });

  const $ = cheerio.load(data);
  const lista = [];

  $('.grille-line').each((_, el) => {
    const p = $(el);

    const fecha = (p.attr('class') || '')
      .match(/\b20\d{6}\b/)?.[0];

    const hora = clean(p.find('.grille-time').first().text())
      .match(/\b(\d{1,2})H(\d{2})\b/i);

    const titulo = clean(
      p.find('.program-title-sm').first().text()
    );

    const categoria = clean(
      p.find('.genre-first').first().text()
    );

    if (!fecha || !hora || !titulo) return;

    const fechaISO =
      `${fecha.slice(0,4)}-${fecha.slice(4,6)}-${fecha.slice(6,8)}`;

    const horaISO =
      `${hora[1].padStart(2,'0')}:${hora[2]}`;

    const inicio = dayjs.tz(
      `${fechaISO} ${horaISO}`,
      'YYYY-MM-DD HH:mm',
      ZONE
    );

    if (!inicio.isValid()) return;

    lista.push({
      id, nombre, fecha, hora:horaISO,
      titulo, categoria, inicio
    });
  });

  lista.sort((a,b) =>
    a.inicio.valueOf() - b.inicio.valueOf()
  );

  return lista;
}

async function main() {
  const todos = [];
  const errores = [];

  for (const canal of canales) {
    try {
      const lista = await extraer(canal);

      if (!lista.length) {
        throw new Error('No se encontraron programas');
      }

      todos.push(...lista);

      const dias = new Set(lista.map(p => p.fecha));

      console.log(
        `${canal[2]}: ${lista.length} programas, ${dias.size} dias`
      );
    } catch(e) {
      errores.push(`${canal[2]}: ${e.message}`);
      console.log('ERROR:', canal[2], e.message);
    }

    await new Promise(r => setTimeout(r, 700));
  }

  if (errores.length) {
    console.error('Extraccion incompleta:', errores);
    process.exitCode = 1;
    return;
  }

  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n';
  xml += '<tv generator-info-name="SNRT Personal">\n';

  for (const [,id,nombre] of canales) {
    xml += `<channel id="${esc(id)}">`;
    xml += `<display-name>${esc(nombre)}</display-name>`;
    xml += '</channel>\n';
  }

  let exportados = 0;
  let duplicados = 0;
  let sinFinal = 0;
  let saltos = 0;

  const claves = new Set();

  for (const [,id] of canales) {
    const lista = todos.filter(p => p.id === id);

    for (let i = 0; i < lista.length; i++) {
      const p = lista[i];
      const siguiente = lista[i+1];

      const clave = `${id}|${p.inicio.valueOf()}`;

      if (claves.has(clave)) {
        duplicados++;
        continue;
      }

      claves.add(clave);

      let stop = '';

      if (siguiente) {
        const minutos = siguiente.inicio.diff(
          p.inicio, 'minute'
        );

        if (minutos > 0 && minutos <= 300) {
          stop = ` stop="${xmlTime(siguiente.inicio)}"`;
        } else {
          saltos++;
        }
      }

      if (!stop) sinFinal++;

      xml += `<programme start="${xmlTime(p.inicio)}"`;
      xml += `${stop} channel="${esc(id)}">\n`;
      xml += `<title lang="ar">${esc(p.titulo)}</title>\n`;

      if (p.categoria) {
        xml += `<category lang="ar">`;
        xml += `${esc(p.categoria)}</category>\n`;
      }

      xml += '</programme>\n';
      exportados++;
    }
  }

  xml += '</tv>\n';

  fs.writeFileSync(
    'snrt-marruecos.xml', xml, 'utf8'
  );

  fs.writeFileSync(
    'snrt-marruecos.json',
    JSON.stringify(todos.map(p => ({
      ...p,
      inicio:p.inicio.format()
    })), null, 2),
    'utf8'
  );

  console.log('\n===== RESUMEN =====');
  console.log('Canales:', canales.length);
  console.log('Programas:', exportados);
  console.log('Duplicados:', duplicados);
  console.log('Sin final:', sinFinal);
  console.log('Intervalos anomalos:', saltos);
  console.log('Archivo: snrt-marruecos.xml');
}

main().catch(e => {
  console.error(e);
  process.exitCode = 1;
});

