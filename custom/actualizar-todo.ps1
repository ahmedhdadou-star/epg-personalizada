# Actualizador integral para C:\Users\ahmed\Desktop\epg
# PowerShell 5.1. No incluye grabbers de diagnostico ni fuentes descartadas.
param([switch]$OmitirArabe)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = $PSScriptRoot
if (-not $base) { throw 'Guarda el archivo .ps1 dentro de la carpeta epg.' }
Set-Location $base
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $base ("_actualizacion_$stamp")
New-Item -ItemType Directory -Path $work -Force | Out-Null
$log = Join-Path $base 'actualizar-todo-informe.txt'
$report = [System.Collections.Generic.List[string]]::new()
$ok = [System.Collections.Generic.List[string]]::new()
$fallos = [System.Collections.Generic.List[string]]::new()
$fuentes = @(
    @{ Dest='movistar.xml';        Selecciones=@('movistar-seleccion.channels.xml') },
    @{ Dest='movistar-nuevos.xml'; Selecciones=@('movistar-nuevos.channels.xml') },
    @{ Dest='movistar-popup.xml'; Selecciones=@('movistar-popup.channels.xml') },
    @{ Dest='orange-cine.xml';     Selecciones=@('orange-cine.channels.xml') },
    @{ Dest='epgshare-deportes.xml'; Selecciones=@('epgshare-deportes.channels.xml') },
    @{ Dest='pt-meo.xml';          Selecciones=@('pt-sports-meo.channels.xml') },
    @{ Dest='pt-dazn-vodafone.xml'; Selecciones=@('pt-dazn-vodafone.channels.xml') },
    @{ Dest='hub-epgshare.xml';    Selecciones=@('hub-epgshare.channels.xml') },
    @{ Dest='sky-bundesliga.xml'; Selecciones=@('sky-bundesliga.channels.xml') },
    @{ Dest='sky-nz-premier-league.xml'; Selecciones=@('sky-nz-premier-league.channels.xml') },
    @{ Dest='now-4k.xml';         Selecciones=@('now-4k.channels.xml') },
    @{ Dest='bein.xml';           Selecciones=@('bein-seleccion.channels.xml','beinsports-mena.channels.xml') },
    @{ Dest='arabic-sports-alkass.xml'; Selecciones=@('arabic-sports-alkass.channels.xml') },
    @{ Dest='aljazeera-arabic.xml'; Selecciones=@('aljazeera-arabic.channels.xml') }
)
function Cargar-XML([string]$ruta) {
    [xml]$x = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8
    if ($x.DocumentElement.LocalName -ne 'tv') { throw "No es XMLTV: $ruta" }
    return $x
}
function Probar-XML([string]$ruta, [bool]$vigente=$true) {
    if (-not (Test-Path -LiteralPath $ruta)) { return 0 }
    try {
        $doc = Cargar-XML $ruta
        $programas = @($doc.SelectNodes('/tv/programme'))
        if ($programas.Count -eq 0 -or @($doc.SelectNodes('/tv/channel')).Count -eq 0) { return 0 }
        if ($vigente) {
            $limite = [DateTime]::UtcNow.AddHours(-48).ToString('yyyyMMddHHmmss')
            $recientes = @($programas | Where-Object {
                $s = $_.GetAttribute('start')
                $s.Length -ge 14 -and $s.Substring(0,14) -ge $limite
            })
            if ($recientes.Count -eq 0) { return 0 }
        }
        return $programas.Count
    } catch { return 0 }
}
# Corregir el desfase observado exclusivamente en fuentes portuguesas nuevas.
function Ajustar-HoraPortugal([string]$ruta) {
    $doc = Cargar-XML $ruta
    $cambiados = 0
    foreach ($p in @($doc.SelectNodes('/tv/programme'))) {
        foreach ($campo in @('start','stop')) {
            $valor = $p.GetAttribute($campo)
            if (-not $valor) { continue }
            if ($valor -notmatch '^(\d{14})(?:\s+([+-]\d{4}))?$') {
                throw "Fecha XMLTV inesperada: $valor"
            }
            $fecha = [datetime]::ParseExact($matches[1],'yyyyMMddHHmmss',[cultureinfo]::InvariantCulture)
            $nueva = $fecha.AddHours(-1).ToString('yyyyMMddHHmmss',[cultureinfo]::InvariantCulture)
            $offset = if ($matches[2]) { ' ' + $matches[2] } else { '' }
            $p.SetAttribute($campo, $nueva + $offset)
        }
        $cambiados++
    }
    if ($cambiados -eq 0) { throw 'Sin programas portugueses que ajustar' }
    $doc.Save($ruta)
    Write-Host "Portugal: -1 hora aplicada a $cambiados programas nuevos en $(Split-Path -Leaf $ruta)"
}
function Grabar([string]$salida, [string[]]$selecciones) {
    $seleccion = $null
    foreach ($nombre in $selecciones) {
        if (Test-Path -LiteralPath (Join-Path $base $nombre)) { $seleccion = $nombre; break }
    }
    if (-not $seleccion) { $fallos.Add("$salida : falta $($selecciones -join ' / ')"); return $null }
    $dest = Join-Path $work $salida
    $canales = Join-Path $base $seleccion
    Write-Host "`n>>> $salida (seleccion: $seleccion)" -ForegroundColor Cyan
    try {
        & npm.cmd run grab -- "--channels=$canales" "--output=$dest" '--days=2' '--maxConnections=1' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm salio con codigo $LASTEXITCODE" }
        $count = Probar-XML $dest $true
        if ($count -eq 0) { throw 'XML vacio, invalido o sin programacion reciente' }
        if ($salida -in @('pt-meo.xml','pt-dazn-vodafone.xml')) {
            Ajustar-HoraPortugal $dest
        }
        $ok.Add("$salida : $count programas nuevos ($seleccion)")
        return $dest
    } catch {
        $fallos.Add("$salida : $($_.Exception.Message)")
        Write-Warning "Fallo $salida; se intentara conservar la version anterior."
        return $null
    }
}
function Unir-Dos([string]$uno, [string]$dos, [string]$salida) {
    $a = Cargar-XML $uno; $b = Cargar-XML $dos
    [xml]$d = '<tv generator-info-name="EPG agregada" />'
    $ids = [System.Collections.Generic.HashSet[string]]::new()
    $claves = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($origen in @($a,$b)) {
        foreach ($c in $origen.SelectNodes('/tv/channel')) {
            $id=$c.GetAttribute('id')
            if ($ids.Add($id)) { [void]$d.DocumentElement.AppendChild($d.ImportNode($c,$true)) }
        }
        foreach ($p in $origen.SelectNodes('/tv/programme')) {
            $id=$p.GetAttribute('channel'); $start=$p.GetAttribute('start')
            if ($ids.Contains($id) -and $claves.Add("$id|$start")) {
                [void]$d.DocumentElement.AppendChild($d.ImportNode($p,$true))
            }
        }
    }
    $d.Save($salida)
}
function Filtrar-Canal([string]$entrada,[string]$salida,[string]$id) {
    $src = Cargar-XML $entrada
    [xml]$dst = '<tv generator-info-name="EPG canal seleccionado" />'
    $canal = $src.SelectSingleNode("/tv/channel[@id='$id']")
    if (-not $canal) { throw "No existe canal solicitado: $id" }
    [void]$dst.DocumentElement.AppendChild($dst.ImportNode($canal,$true))
    foreach ($p in $src.SelectNodes("/tv/programme[@channel='$id']")) {
        [void]$dst.DocumentElement.AppendChild($dst.ImportNode($p,$true))
    }
    if (@($dst.SelectNodes('/tv/programme')).Count -eq 0) { throw "Canal vacio: $id" }
    $dst.Save($salida)
}
function Filtrar-AbuDhabi([string]$entrada,[string]$salida) {
    $src=Cargar-XML $entrada
    [xml]$dst='<tv generator-info-name="OSN Abu Dhabi Sports 1" />'
    $id='AbuDhabiSports1.ae'
    $canal=$src.SelectSingleNode("/tv/channel[@id='$id']")
    if (-not $canal) { throw 'OSN no ha devuelto Abu Dhabi Sports 1' }
    [void]$dst.DocumentElement.AppendChild($dst.ImportNode($canal,$true))
    $visto=[System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $src.SelectNodes("/tv/programme[@channel='$id']")) {
        $clave=$p.OuterXml
        if ($visto.Add($clave)) { [void]$dst.DocumentElement.AppendChild($dst.ImportNode($p,$true)) }
    }
    $dst.Save($salida)
}
try {
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'No se encuentra npm.cmd.' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'No se encuentra Node.js.' }
    if (-not (Test-Path (Join-Path $base 'node_modules'))) { throw 'No se encuentra node_modules.' }
    if (-not (Test-Path (Join-Path $base 'unir-todas-epg.ps1'))) { throw 'Falta unir-todas-epg.ps1.' }
    $report.Add("Actualizacion $stamp")
    # 1. EPG arabe: 31 ElCinema + 6 SNRT + 2M. 38 canales.
    if (-not $OmitirArabe) {
        if (-not (Test-Path (Join-Path $base 'actualizar-epg-arabe.ps1'))) {
            $fallos.Add('Arabe: falta actualizar-epg-arabe.ps1; se intentara copia existente.')
        } else {
            Write-Host "`n>>> Actualizando 38 canales arabes" -ForegroundColor Cyan
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'actualizar-epg-arabe.ps1')
                if ($LASTEXITCODE -ne 0) { throw "Actualizador arabe: codigo $LASTEXITCODE" }
                $ok.Add('Arabe: actualizado mediante SNRT + ElCinema + 2M.')
            } catch { $fallos.Add("Arabe: $($_.Exception.Message)") }
        }
    }
    $arabe = Join-Path $base 'epg-arabe.xml'
    $arabeValido = $false
    if ((Probar-XML $arabe $false) -gt 0) {
        $d = Cargar-XML $arabe
        $ids = @($d.SelectNodes('/tv/channel') | ForEach-Object { $_.GetAttribute('id') })
        $arabeValido = ($ids.Count -ge 38 -and '2M.ma' -in $ids -and 'Arryadia.ma' -in $ids)
    }
    if (-not $arabeValido) {
        $alternativa = Join-Path $base 'epg-arabe-v3.xml'
        if ((Probar-XML $alternativa $false) -eq 0) { throw 'No hay EPG arabe de 38 canales. Ejecuta/actualiza actualizar-epg-arabe.ps1 antes de fusionar.' }
        $arabe = $alternativa
        $fallos.Add('Arabe: usando copia v3 anterior, comprobar fechas.')
    }
    Copy-Item -LiteralPath $arabe -Destination (Join-Path $work 'epg-arabe.xml')
    # Respaldo general: se recupera una sola vez la ultima guia publicada.
    # El fusionador reutilizara exclusivamente programas aun vigentes de canales
    # cuyo grabber haya fallado o no haya devuelto programacion vigente.
    $respaldo = Join-Path $work 'epg-respaldo.xml'
    try {
        Invoke-WebRequest -Uri 'https://ahmedhdadou-star.github.io/epg-personalizada/epg-total.xml' -OutFile $respaldo -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $copia = Cargar-XML $respaldo
        if (@($copia.SelectNodes('/tv/channel')).Count -lt 50 -or @($copia.SelectNodes('/tv/programme')).Count -lt 100) {
            throw 'Respaldo publicado insuficiente'
        }
        $ok.Add('Respaldo: ultima EPG publicada descargada y validada.')
    } catch {
        Remove-Item $respaldo -Force -ErrorAction SilentlyContinue
        $fallos.Add("Respaldo publicado no disponible: $($_.Exception.Message)")
    }
    # 2. Grabbers iptv-org. Solo seleccionados y no archivos de diagnostico.
    foreach ($f in $fuentes) { [void](Grabar $f.Dest $f.Selecciones) }
    # Medi1 TV Arabic: fuente oficial. Ejecutar en la carpeta temporal para no
    # modificar la ultima guia correcta hasta que XML y fechas esten validados.
    Write-Host "`n>>> medi1-arabic.xml (Medi1 oficial)" -ForegroundColor Cyan
    try {
        $scriptMedi1 = Join-Path $base 'medi1-oficial.cjs'
        if (-not (Test-Path -LiteralPath $scriptMedi1)) { throw 'Falta medi1-oficial.cjs' }
        Push-Location $work
        try {
            & node $scriptMedi1 | Out-Host
            $medi1Exit = $LASTEXITCODE
        } finally { Pop-Location }
        if ($medi1Exit -ne 0) { throw "node termino con codigo $medi1Exit" }
        $medi1Nuevo = Join-Path $work 'medi1-arabic.xml'
        $medi1Count = Probar-XML $medi1Nuevo $true
        if ($medi1Count -eq 0) { throw 'XML vacio, invalido o sin programacion reciente' }
        $medi1Doc = Cargar-XML $medi1Nuevo
        if (-not $medi1Doc.SelectSingleNode("/tv/channel[@id='Medi1TVArabic.ma']")) {
            throw 'Falta el identificador Medi1TVArabic.ma'
        }
        if (@($medi1Doc.SelectNodes("/tv/programme[@channel='Medi1TVArabic.ma']")).Count -eq 0) {
            throw 'Medi1 TV Arabic no contiene programas'
        }
        $ok.Add("medi1-arabic.xml : $medi1Count programas nuevos (Medi1 oficial)")
    } catch {
        $fallos.Add("medi1-arabic.xml : $($_.Exception.Message)")
        # El proceso existente recuperara la ultima guia valida, si existe.
        Remove-Item -LiteralPath (Join-Path $work 'medi1-arabic.xml') -Force -ErrorAction SilentlyContinue
        Write-Warning 'Fallo Medi1 oficial; se intentara conservar la version anterior.'
    }
    # UK Sky + excepcion TNT Ultimate de MyTelly.
    $sky = Grabar '_uk-sky.xml' @('uk-sports-sky-seleccion.channels.xml','uk-sports-sky.channels.xml')
    $tnt = Grabar '_uk-mytelly.xml' @('uk-sports-mytelly.channels.xml')
    if ($sky -and $tnt) {
        try {
            $tntSolo = Join-Path $work '_tnt-solo.xml'
            Filtrar-Canal $tnt $tntSolo 'tntsportsultimate.uk'
            Unir-Dos $sky $tntSolo (Join-Path $work 'uk-sports.xml')
            $ok.Add('uk-sports.xml : Sky + TNT Ultimate fusionados')
        } catch {
            $fallos.Add("uk-sports.xml : $($_.Exception.Message)")
            $sky = $null; $tnt = $null
        }
    } else { $fallos.Add('uk-sports.xml : la combinacion nueva no esta completa') }
    # OSN exclusivamente Abu Dhabi Sports 1; otras señales de prueba se excluyen.
    $osn = Grabar '_osn-prueba.xml' @('arabic-sports-prueba.channels.xml')
    if ($osn) {
        try {
            Filtrar-AbuDhabi $osn (Join-Path $work 'arabic-sports-sin-duplicados.xml')
            if ((Probar-XML (Join-Path $work 'arabic-sports-sin-duplicados.xml') $true) -eq 0) {
                throw 'OSN no devolvio emisiones actuales'
            }
            $ok.Add('Abu Dhabi Sports 1: filtrado; revisar duracion excepcional.')
        } catch { $fallos.Add("Abu Dhabi Sports 1: $($_.Exception.Message)") }
    }
    # 3. Conservar fuentes anteriores si no se han podido regenerar.
    $merge = Join-Path $work 'unir-todas-epg.ps1'
    Copy-Item (Join-Path $base 'unir-todas-epg.ps1') $merge
    $salidas = @($fuentes | ForEach-Object { $_.Dest }) + @('uk-sports.xml','arabic-sports-sin-duplicados.xml','medi1-arabic.xml')
    foreach ($nombre in $salidas) {
        $nuevo = Join-Path $work $nombre
        $anterior = Join-Path $base $nombre
        if (-not (Test-Path $nuevo) -and (Probar-XML $anterior $false) -gt 0) {
            Copy-Item $anterior $nuevo
            $fallos.Add("$nombre : usando copia anterior (podria estar caducada)")
        }
    }
    # 4. Fusion completa aislada. No se toca epg-total.xml hasta validar.
    Push-Location $work
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $merge
        if ($LASTEXITCODE -ne 0) { throw "Fusion: codigo $LASTEXITCODE" }
    } finally { Pop-Location }
    $total = Join-Path $work 'epg-total.xml'
    $n = Probar-XML $total $true
    if ($n -eq 0) { throw 'La fusion ha generado XML vacio, invalido o enteramente caducado.' }
    $t = Cargar-XML $total
    $ids = @($t.SelectNodes('/tv/channel') | ForEach-Object { $_.GetAttribute('id') })
    # La fusion adapta algunos IDs a los tvg-id del proveedor IPTV.
    # Validar los identificadores publicados, admitiendo el original por compatibilidad.
    $esenciales = @(
        @('mbc1.ae','MBC1.ae'),
        @('alaoula.ae','AlAoula.ma'),
        @('2mmaroc.es','2M.ma'),
        @('Arryadia.ma')
    )
    foreach ($alternativas in $esenciales) {
        if (@($alternativas | Where-Object { $_ -in $ids }).Count -eq 0) {
            throw "Falta canal esencial en la fusion: $($alternativas -join ' / ')"
        }
    }
    # 5. Publicar: backup del total anterior y despues copiar solo las fuentes nuevas.
    $destino = Join-Path $base 'epg-total.xml'
    if (Test-Path $destino) { Copy-Item $destino (Join-Path $base 'epg-total-anterior.xml') -Force }
    Copy-Item $total $destino -Force
    foreach ($nombre in $salidas) {
        if (Test-Path (Join-Path $work $nombre)) {
            # No publicar copias antiguas como si fueran descargas nuevas.
            $actualizado = @($ok | Where-Object { $_ -like "$nombre :*" }).Count -gt 0
            if ($nombre -eq 'uk-sports.xml') { $actualizado = [bool]($sky -and $tnt) }
            if ($nombre -eq 'arabic-sports-sin-duplicados.xml') {
                $actualizado = @($ok | Where-Object { $_ -like 'Abu Dhabi Sports 1:*' }).Count -gt 0
            }
            if ($actualizado) { Copy-Item (Join-Path $work $nombre) (Join-Path $base $nombre) -Force }
        }
    }
    Copy-Item (Join-Path $work 'epg-total-informe.txt') (Join-Path $base 'epg-total-informe.txt') -Force
    $report.Add("OK total: $($ids.Count) canales; $n programas")
    $report.Add('NUEVOS:'); foreach ($l in $ok) { $report.Add($l) }
    $report.Add('ADVERTENCIAS:'); foreach ($l in $fallos) { $report.Add($l) }
    $report | Set-Content -LiteralPath $log -Encoding UTF8
    Write-Host "`nEPG total actualizada: $($ids.Count) canales; $n programas" -ForegroundColor Green
    Write-Host "Advertencias: $($fallos.Count) | Informe: $log"
    Write-Host 'URL TiviMate: http://192.168.1.148:8000/epg-total.xml'
} catch {
    $report.Add("ERROR FINAL: $($_.Exception.Message)")
    foreach ($l in $fallos) { $report.Add($l) }
    $report | Set-Content -LiteralPath $log -Encoding UTF8
    Write-Error "Fallo la actualizacion: $($_.Exception.Message). Se conserva epg-total.xml anterior."
    exit 1
}