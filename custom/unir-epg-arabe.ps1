# Ejecutar en C:\Users\ahmed\Desktop\epg
# Fuentes: snrt-marruecos.xml (local) y elcinema-iptv-filtrado.xml
$ErrorActionPreference = 'Stop'
$carpeta = $PSScriptRoot
$snrtRuta = Join-Path $carpeta 'snrt-marruecos.xml'
$elcinemaRuta = Join-Path $carpeta 'elcinema-iptv-filtrado.xml'
$destino = Join-Path $carpeta 'epg-arabe.xml'

foreach ($ruta in @($snrtRuta, $elcinemaRuta)) {
    if (-not (Test-Path -LiteralPath $ruta)) {
        throw "Archivo necesario no encontrado: $ruta"
    }
}

$idsSNRT = @(
    'AlAoula.ma', 'Athaqafia.ma', 'AlMaghribia.ma',
    'Assadissa.ma', 'TamazightTV.ma'
)

[xml]$snrt = Get-Content -LiteralPath $snrtRuta -Raw -Encoding UTF8
[xml]$elcinema = Get-Content -LiteralPath $elcinemaRuta -Raw -Encoding UTF8

$salida = New-Object System.Xml.XmlDocument
$declaracion = $salida.CreateXmlDeclaration('1.0', 'UTF-8', $null)
[void]$salida.AppendChild($declaracion)
$tv = $salida.CreateElement('tv')
$tv.SetAttribute('generator-info-name', 'EPG Arabe Personal - SNRT + ElCinema')
[void]$salida.AppendChild($tv)

$canales = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$clavesProgramas = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$cuenta = @{}

# Una fuente por canal: SNRT tiene prioridad solamente en los cinco identificadores indicados.
foreach ($fuente in @($snrt, $elcinema)) {
    foreach ($canal in $fuente.SelectNodes('/tv/channel')) {
        $id = $canal.GetAttribute('id')
        if (($fuente -eq $snrt -and $id -notin $idsSNRT) -or
            ($fuente -eq $elcinema -and $id -in $idsSNRT)) { continue }
        if ($canales.Add($id)) {
            [void]$tv.AppendChild($salida.ImportNode($canal, $true))
            $cuenta[$id] = 0
        }
    }
}

$sinCanal = 0
$duplicados = 0
foreach ($fuente in @($snrt, $elcinema)) {
    foreach ($programa in $fuente.SelectNodes('/tv/programme')) {
        $id = $programa.GetAttribute('channel')
        if (($fuente -eq $snrt -and $id -notin $idsSNRT) -or
            ($fuente -eq $elcinema -and $id -in $idsSNRT)) { continue }
        if (-not $canales.Contains($id)) { $sinCanal++; continue }
        $inicio = $programa.GetAttribute('start')
        $fin = $programa.GetAttribute('stop')
        $titulo = $programa.SelectSingleNode('title')
        $nombre = if ($null -ne $titulo) { $titulo.InnerText } else { '' }
        $clave = "$id|$inicio|$fin|$nombre"
        if (-not $clavesProgramas.Add($clave)) { $duplicados++; continue }
        [void]$tv.AppendChild($salida.ImportNode($programa, $true))
        $cuenta[$id]++
    }
}

$faltanSNRT = @($idsSNRT | Where-Object { -not $canales.Contains($_) })
if ($faltanSNRT.Count -gt 0 -or $sinCanal -gt 0) {
    throw "Validacion fallida: SNRT ausentes: $($faltanSNRT -join ', '); programas sin canal: $sinCanal. No se ha guardado el XML."
}

$opciones = New-Object System.Xml.XmlWriterSettings
$opciones.Encoding = New-Object System.Text.UTF8Encoding($false)
$opciones.Indent = $true
$opciones.CloseOutput = $true
$escritor = [System.Xml.XmlWriter]::Create($destino, $opciones)
try { $salida.Save($escritor) } finally { $escritor.Dispose() }

[xml]$verificacion = Get-Content -LiteralPath $destino -Raw -Encoding UTF8
$programasFinales = @($verificacion.SelectNodes('/tv/programme'))
$sinFin = @($programasFinales | Where-Object { -not $_.HasAttribute('stop') }).Count
Write-Host "`n===== EPG ARABE CONJUNTA ====="
Write-Host "Canales: $($canales.Count)"
Write-Host "Programas: $($programasFinales.Count)"
Write-Host "SNRT (5 canales): $((@($idsSNRT | ForEach-Object { $cuenta[$_] }) | Measure-Object -Sum).Sum)"
Write-Host "Sin hora final: $sinFin"
Write-Host "Duplicados exactos eliminados: $duplicados"
Write-Host "Programas sin canal: $sinCanal"
Write-Host "Archivo: $destino"
