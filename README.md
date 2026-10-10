# EPG personalizada

Generación automática de una EPG XMLTV personalizada para TiviMate.

## Estructura

- `custom/`: solo archivos personalizados, grabbers, selecciones y configuraciones modificadas.
- `.github/workflows/actualizar-epg.yml`: descarga una copia limpia de `iptv-org/epg`, aplica las personalizaciones, genera la EPG y la publica.
- `public/`: se crea automáticamente durante el workflow.

## Actualización

La EPG se puede regenerar:
- manualmente desde **Actions → Actualizar EPG → Run workflow**
- automáticamente al cambiar archivos dentro de `custom/`
- automáticamente varias veces al día

## TiviMate

La URL final será:

`https://ahmedhdadou-star.github.io/epg-personalizada/epg-total.xml`

## Importante

No se versiona una copia completa de `iptv-org/epg`. El workflow la descarga de nuevo en cada ejecución y después copia encima las personalizaciones guardadas en `custom/`.
