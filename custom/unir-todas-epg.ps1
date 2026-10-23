# Fusion de guias XMLTV probadas. Ejecutar desde la carpeta epg.
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $base) { $base = (Get-Location).Path }
$salida = Join-Path $base 'epg-total.xml'
$temporal = Join-Path $base 'epg-total.tmp.xml'
$reporte = Join-Path $base 'epg-total-informe.txt'

# Orden de prioridad: si una fuente contiene el mismo canal y hora de inicio,
# se conserva la primera y se registra el conflicto.
# Un solo archivo por cada conjunto de alternativas (no mezclar versiones).
$grupos = @(
    @('epg-arabe.xml','epg-arabe-v3.xml','epg-arabe-v2.xml'),
    @('arabic-sports-alkass.xml'),
    @('arabic-sports-sin-duplicados.xml'),
    @('movistar.xml'),
    @('movistar-nuevos.xml'),
    @('movistar-popup.xml'),
    @('orange-cine.xml'),
    @('epgshare-deportes.xml'),
    @('pt-meo.xml'),
    @('pt-dazn-vodafone.xml'),
    @('uk-sports.xml'),
    @('hub-epgshare.xml'),
    @('sky-bundesliga.xml'),
    @('uk-sports-ultrahd.xml'),
    @('sky-nz-premier-league.xml'),
    @('now-4k.xml'),
    @('bein.xml'),
    @('medi1.xml','medi1tv.xml','medi1-arabic.xml'),
    @('aljazeera-arabic.xml','aljazeera.xml')
)

$elegidos = [System.Collections.Generic.List[string]]::new()
$faltantes = [System.Collections.Generic.List[string]]::new()
foreach ($grupo in $grupos) {
    $archivo = $null
    foreach ($alternativa in $grupo) {
        $ruta = Join-Path $base $alternativa
        if (Test-Path -LiteralPath $ruta -PathType Leaf) {
            $archivo = $ruta
            break
        }
    }
    if ($archivo) { $elegidos.Add($archivo) }
    else { $faltantes.Add(($grupo -join ' / ')) }
}
if ($elegidos.Count -eq 0) { throw 'No se han encontrado XMLTV seleccionados. Guarda el script en tu carpeta epg.' }

[xml]$destino = '<?xml version="1.0" encoding="utf-8"?><tv generator-info-name="EPG personalizada" />'
$idsCanales = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$inicios = @{} # canal|start -> clave de evento, para prevenir colisiones
$duplicados = 0
$conflictos = [System.Collections.Generic.List[string]]::new()
$anomalos = [System.Collections.Generic.List[string]]::new()
$estadisticas = [System.Collections.Generic.List[object]]::new()

foreach ($ruta in $elegidos) {
    $nombre = Split-Path -Leaf $ruta
    try { [xml]$origen = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 }
    catch { throw "Error leyendo ${nombre}: $($_.Exception.Message)" }
    if (-not $origen.DocumentElement -or $origen.DocumentElement.LocalName -ne 'tv') {
        throw "No es XMLTV valido: $nombre"
    }
    $alta = 0
    foreach ($c in @($origen.SelectNodes('/tv/channel'))) {
        $id = $c.GetAttribute('id')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($idsCanales.Add($id)) {
            [void]$destino.DocumentElement.AppendChild($destino.ImportNode($c, $true))
            $alta++
        }
    }
    $aplicados = 0
    foreach ($p in @($origen.SelectNodes('/tv/programme'))) {
        $id = $p.GetAttribute('channel')
        $start = $p.GetAttribute('start')
        if (-not $idsCanales.Contains($id) -or -not $start) {
            $anomalos.Add("Sin canal o inicio: $nombre / $id / $start")
            continue
        }
        $stop = $p.GetAttribute('stop')
        $titleNode = $p.SelectSingleNode('title')
        $title = if ($titleNode) { $titleNode.InnerText } else { '' }
        $clave = "$id`n$start"
        $datos = "$stop`n$title"
        if ($inicios.ContainsKey($clave)) {
            if ($inicios[$clave] -eq $datos) { $duplicados++ }
            else { $conflictos.Add("$id | $start | $nombre | titulo: $title | prioridad anterior mantenida") }
            continue
        }
        # No inventamos finales y avisamos de intervalos excepcionalmente largos.
        if ($stop -and $start.Length -ge 12 -and $stop.Length -ge 12) {
            try {
                $a = [datetime]::ParseExact($start.Substring(0,12),'yyyyMMddHHmm',[cultureinfo]::InvariantCulture)
                $b = [datetime]::ParseExact($stop.Substring(0,12),'yyyyMMddHHmm',[cultureinfo]::InvariantCulture)
                $duracion = ($b - $a).TotalMinutes
                if ($duracion -le 0 -or $duracion -gt 720) {
                    $anomalos.Add("Duracion atipica ($duracion min): $nombre / $id / $start")
                }
            } catch { $anomalos.Add("Formato horario irregular: $nombre / $id / $start") }
        }
        $inicios[$clave] = $datos
        [void]$destino.DocumentElement.AppendChild($destino.ImportNode($p, $true))
        $aplicados++
    }
    $estadisticas.Add([pscustomobject]@{ Archivo = $nombre; CanalesNuevos = $alta; ProgramasNuevos = $aplicados })
}

if ($idsCanales.Count -eq 0 -or $inicios.Count -eq 0) { throw 'No se encontro programacion valida. No se modifica la salida.' }
# Equivalencias verificadas con los tvg-id de Moha.m3u.
# Se aplican exclusivamente al XMLTV combinado; los IDs de los grabbers no cambian.
# En caso de colision con un canal ya existente, se conserva el ID original.
$equivalencias = [ordered]@{
    'movistarpluses.es' = 'movistarpluspluses.es'
    'mplusestrenos.es' = 'M+.Estrenos.es'
    'cosmoes.es' = 'Cosmopolitan.es'
    'syfyes.es' = 'syfyespaña.es'
    'tcm.es' = 'tcmespaña.es'
    'discoverychanneles.es' = 'Discovery.Channel.es'
    'movistargolfes.es' = 'mplusgolfes.es'
    'goles.es' = 'golplay.es'
    'movistar-test-MBALCT.es' = 'mplusbaloncestoes.es'
    'movistar-test-MBALC2.es' = 'mplusbaloncesto2es.es'
    'movistar-test-MBALC3.es' = 'mplusbaloncesto3es.es'
    'movistar-test-DAZMOT.es' = 'daznmotogpes.es'
    'AlJazeera.qa@Arabic' = 'aljazeera.ae'
    'AlAoula.ma' = 'alaoula.ae'
    '2M.ma' = '2mmaroc.es'
    'MBC1.ae' = 'mbc1.ae'
    'RotanaCinemaEgypt.eg' = 'rotanacinemaegypt.ae'
}
$equivalenciasAplicadas = [System.Collections.Generic.List[string]]::new()
$equivalenciasOmitidas = [System.Collections.Generic.List[string]]::new()
foreach ($idOriginal in $equivalencias.Keys) {
    $idNuevo = $equivalencias[$idOriginal]
    $canal = $destino.SelectSingleNode("/tv/channel[@id='$idOriginal']")
    if (-not $canal) { continue }
    if ($idsCanales.Contains($idNuevo)) {
        $equivalenciasOmitidas.Add("$idOriginal -> $idNuevo (destino ocupado)")
        continue
    }
    $canal.SetAttribute('id', $idNuevo)
    foreach ($programa in @($destino.SelectNodes("/tv/programme[@channel='$idOriginal']"))) {
        $programa.SetAttribute('channel', $idNuevo)
    }
    [void]$idsCanales.Remove($idOriginal)
    [void]$idsCanales.Add($idNuevo)
    $equivalenciasAplicadas.Add("$idOriginal -> $idNuevo")
}

# Fallback general para TODAS las fuentes de la EPG:
# Si un canal carece de programas vigentes, usar los aun vigentes de la
# ultima guia publicada. La fusion ya aplico las equivalencias M3U.
$respaldo = Join-Path $base 'epg-respaldo.xml'
$recuperados = [System.Collections.Generic.List[string]]::new()
$sinCobertura = [System.Collections.Generic.List[string]]::new()
$umbral = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
if (Test-Path $respaldo) {
    try {
        [xml]$anterior = Get-Content -LiteralPath $respaldo -Raw -Encoding UTF8
        if ($anterior.DocumentElement.LocalName -ne 'tv') { throw 'No es XMLTV' }
        # HashSet de IDs con programacion aun vigente obtenida de fuentes nuevas.
        $conVigentes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($p in @($destino.SelectNodes('/tv/programme'))) {
            $fin = $p.GetAttribute('stop')
            if (-not $fin) { $fin = $p.GetAttribute('start') }
            if ($fin.Length -ge 14 -and $fin.Substring(0,14) -ge $umbral) {
                [void]$conVigentes.Add($p.GetAttribute('channel'))
            }
        }
        foreach ($oldChannel in @($anterior.SelectNodes('/tv/channel'))) {
            $id = $oldChannel.GetAttribute('id')
            if (-not $id -or $conVigentes.Contains($id)) { continue }
            $anterioresVigentes = @($anterior.SelectNodes('/tv/programme') | Where-Object {
                if ($_.GetAttribute('channel') -ne $id) { return $false }
                $fin = $_.GetAttribute('stop')
                if (-not $fin) { $fin = $_.GetAttribute('start') }
                return ($fin.Length -ge 14 -and $fin.Substring(0,14) -ge $umbral)
            })
            if ($anterioresVigentes.Count -eq 0) { continue }
            if ($idsCanales.Add($id)) {
                [void]$destino.DocumentElement.AppendChild($destino.ImportNode($oldChannel, $true))
            }
            $nRecuperados = 0
            foreach ($old in $anterioresVigentes) {
                $inicio = $old.GetAttribute('start')
                $clave = "$id`n$inicio"
                if (-not $inicio -or $inicios.ContainsKey($clave)) { continue }
                $titleNode = $old.SelectSingleNode('title')
                if ($null -eq $titleNode) { continue }
                $inicios[$clave] = "$($old.GetAttribute('stop'))`n$($titleNode.InnerText)"
                [void]$destino.DocumentElement.AppendChild($destino.ImportNode($old, $true))
                $nRecuperados++
            }
            if ($nRecuperados -gt 0) {
                $recuperados.Add("$id : $nRecuperados programas vigentes recuperados")
                [void]$conVigentes.Add($id)
            }
        }
    } catch {
        $anomalos.Add("Respaldo global no utilizable: $($_.Exception.Message)")
    }
}
$vigentesFinales = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$programasVigentes = 0
foreach ($p in @($destino.SelectNodes('/tv/programme'))) {
    $fin = $p.GetAttribute('stop')
    if (-not $fin) { $fin = $p.GetAttribute('start') }
    if ($fin.Length -ge 14 -and $fin.Substring(0,14) -ge $umbral) {
        $programasVigentes++
        [void]$vigentesFinales.Add($p.GetAttribute('channel'))
    }
}
if ($programasVigentes -lt 100 -or $vigentesFinales.Count -lt 10) {
    throw "EPG total insuficiente: $programasVigentes programas vigentes en $($vigentesFinales.Count) canales."
}

# Guardar temporal y verificar de nuevo que es XML bien formado.
$settings = [System.Xml.XmlWriterSettings]::new()
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)
$settings.Indent = $true
$writer = [System.Xml.XmlWriter]::Create($temporal, $settings)
try { $destino.Save($writer) } finally { $writer.Dispose() }
[xml]$verificado = Get-Content -LiteralPath $temporal -Raw -Encoding UTF8
if ($verificado.SelectNodes('/tv/programme').Count -ne $inicios.Count) {
    Remove-Item $temporal -ErrorAction SilentlyContinue
    throw 'Error de verificacion: recuento diferente. Se conserva el XML anterior.'
}
if (Test-Path $salida) { Copy-Item $salida (Join-Path $base 'epg-total-anterior.xml') -Force }
Move-Item $temporal $salida -Force

$lineas = @('EPG TOTAL - Informe', "Canales: $($idsCanales.Count)", "Programas: $($inicios.Count)", "Duplicados exactos aproximados: $duplicados", "Conflictos de inicio: $($conflictos.Count)", "Advertencias de datos: $($anomalos.Count)", '', 'ARCHIVOS INCLUIDOS')
$lineas += $estadisticas | ForEach-Object { "$($_.Archivo): $($_.ProgramasNuevos) programas; $($_.CanalesNuevos) canales nuevos" }
$lineas += @('', 'PROGRAMACION VIGENTE RECUPERADA DEL RESPALDO PUBLICADO')
$lineas += $recuperados
$lineas += @('', 'EQUIVALENCIAS TVG-ID APLICADAS')
$lineas += $equivalenciasAplicadas
$lineas += @('', 'EQUIVALENCIAS OMITIDAS POR COLISION')
$lineas += $equivalenciasOmitidas
$lineas += @('', 'FUENTES NO ENCONTRADAS')
$lineas += $faltantes
$lineas += @('', 'CONFLICTOS (mismo canal e inicio, prevalece el primer archivo)')
$lineas += $conflictos
$lineas += @('', 'ADVERTENCIAS (revisar antes del uso permanente)')
$lineas += $anomalos
[System.IO.File]::WriteAllLines($reporte, [string[]]$lineas, [System.Text.UTF8Encoding]::new($true))

$estadisticas | Format-Table -AutoSize
Write-Host "`nXML: $salida"
Write-Host "Canales: $($idsCanales.Count) | Programas: $($inicios.Count) | Conflictos: $($conflictos.Count) | Advertencias: $($anomalos.Count)"
Write-Host "Informe: $reporte"
Write-Host 'NOTA: algunos datos antiguos, incompletos o con solapes pueden seguir presentes. Revisa el informe.'
