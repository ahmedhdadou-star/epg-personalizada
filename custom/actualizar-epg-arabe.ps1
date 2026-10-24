# Ejecutar desde cualquier directorio con:
# powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ahmed\Desktop\epg\actualizar-epg-arabe.ps1"
# Este archivo y 2m-actualizable.cjs deben estar en la carpeta epg.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = $PSScriptRoot
$stage = Join-Path $base '_epg_work'
$log = Join-Path $base 'epg-actualizacion.log'
$dest = Join-Path $base 'epg-arabe.xml'
$names = @(
  'snrt-marruecos.cjs', 'elcinema-mbc-rotana.cjs',
  'elcinema-otros-ar.cjs', 'elcinema-todos.channels.xml',
  'elcinema-objetivos.txt', '2m-actualizable.cjs'
)

try {
  Set-Location $base
  foreach ($name in $names) {
    if (-not (Test-Path (Join-Path $base $name))) {
      throw "Falta el archivo $name en $base"
    }
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'No encuentro Node.js en PATH.'
  }
  if (-not (Test-Path (Join-Path $base 'node_modules'))) {
    throw 'Falta node_modules: primero instala las dependencias del proyecto.'
  }
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  New-Item -ItemType Directory -Path $stage | Out-Null
  foreach ($name in $names) { Copy-Item (Join-Path $base $name) $stage }
  # Mantener año de ElCinema actualizado, sin modificar los scripts originales.
  foreach ($name in @('elcinema-mbc-rotana.cjs', 'elcinema-otros-ar.cjs')) {
    $file = Join-Path $stage $name
    $code = [System.IO.File]::ReadAllText($file)
    if ($code -notmatch 'const\s+YEAR\s*=\s*\d{4}') {
      throw "No se encontro YEAR en $name; revisar antes de actualizar."
    }
    $year = [int](Get-Date -Format 'yyyy')
    $code = [regex]::Replace($code, 'const\s+YEAR\s*=\s*\d{4}', "const YEAR = $year")
    [System.IO.File]::WriteAllText($file, $code, (New-Object System.Text.UTF8Encoding($false)))
  }
  Push-Location $stage
  try {
    foreach ($name in @(
      'snrt-marruecos.cjs', 'elcinema-mbc-rotana.cjs',
      'elcinema-otros-ar.cjs', '2m-actualizable.cjs'
    )) {
      Write-Host "`n>>> $name"
      & node $name
      if ($LASTEXITCODE -ne 0) { throw "Fallo la ejecucion de $name" }
    }
  } finally { Pop-Location }

  $paths = @{
    snrt = Join-Path $stage 'snrt-marruecos.xml'
    mbc  = Join-Path $stage 'elcinema-mbc-rotana.xml'
    otros = Join-Path $stage 'elcinema-otros-ar.xml'
    dosm = Join-Path $stage '2m.xml'
  }
  foreach ($path in $paths.Values) {
    if (-not (Test-Path $path)) { throw "No se genero el archivo $path" }
  }

  [xml]$snrt = Get-Content $paths.snrt -Raw -Encoding UTF8
  [xml]$mbc = Get-Content $paths.mbc -Raw -Encoding UTF8
  [xml]$otros = Get-Content $paths.otros -Raw -Encoding UTF8
  [xml]$dosm = Get-Content $paths.dosm -Raw -Encoding UTF8
  $wanted = @(Get-Content (Join-Path $stage 'elcinema-objetivos.txt') -Encoding UTF8 |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (@($wanted | Select-Object -Unique).Count -ne 31) {
    throw 'La lista de seleccion ElCinema debe tener 31 IDs unicos.'
  }
  $snrtIds = @('AlAoula.ma','Arryadia.ma','Athaqafia.ma',
    'AlMaghribia.ma','Assadissa.ma','TamazightTV.ma')
  $priority = @{}
  foreach ($id in $snrtIds) { $priority[$id] = 'SNRT' }
  $priority['2M.ma'] = '2M'
  foreach ($id in $wanted) {
    if ($priority.ContainsKey($id)) { throw "ID en conflicto: $id" }
    $priority[$id] = 'ElCinema'
  }
  $output = New-Object System.Xml.XmlDocument
  [void]$output.AppendChild($output.CreateXmlDeclaration('1.0','UTF-8',$null))
  $tv = $output.CreateElement('tv')
  $tv.SetAttribute('generator-info-name','EPG Arabe Personal')
  [void]$output.AppendChild($tv)
  $channels = @{}
  $counts = @{}
  $dedupe = [System.Collections.Generic.HashSet[string]]::new()
  $data = @(
    @{ name='ElCinema'; source=$mbc },
    @{ name='ElCinema'; source=$otros },
    @{ name='SNRT'; source=$snrt },
    @{ name='2M'; source=$dosm }
  )
  foreach ($entry in $data) {
    foreach ($node in $entry.source.SelectNodes('/tv/channel')) {
      $id = $node.GetAttribute('id')
      if (-not $priority.ContainsKey($id) -or $priority[$id] -ne $entry.name) { continue }
      if ($channels.ContainsKey($id)) { throw "Canal repetido entre fuentes: $id" }
      [void]$tv.AppendChild($output.ImportNode($node, $true))
      $channels[$id] = $true
      $counts[$id] = 0
    }
  }
  foreach ($entry in $data) {
    foreach ($node in $entry.source.SelectNodes('/tv/programme')) {
      $id = $node.GetAttribute('channel')
      if (-not $priority.ContainsKey($id) -or $priority[$id] -ne $entry.name) { continue }
      if (-not $channels.ContainsKey($id)) { throw "Programa sin canal: $id" }
      $start = $node.GetAttribute('start')
      $stop = $node.GetAttribute('stop')
      $titleNode = $node.SelectSingleNode('title')
      if ($null -eq $titleNode -or -not $start) { throw "Programa incompleto: $id" }
      # Ajuste -1h SOLO a programas nuevos de ElCinema (no SNRT, 2M o respaldo).
      if ($entry.name -eq 'ElCinema') {
        foreach ($attr in @('start','stop')) {
          $rawTime = $node.GetAttribute($attr)
          if ($attr -eq 'stop' -and [string]::IsNullOrWhiteSpace($rawTime)) { continue }
          if ($rawTime -notmatch '^(\d{14})(\s+[+-]\d{4})?$') {
            throw "Horario XMLTV ElCinema invalido: $rawTime"
          }
          $datePart = [datetime]::ParseExact($matches[1], 'yyyyMMddHHmmss', [cultureinfo]::InvariantCulture)
          $suffix = if ($matches[2]) { $matches[2] } else { '' }
          $node.SetAttribute($attr, $datePart.AddHours(-1).ToString('yyyyMMddHHmmss', [cultureinfo]::InvariantCulture) + $suffix)
        }
        $start = $node.GetAttribute('start')
        $stop = $node.GetAttribute('stop')
      }
      $key = "$id|$start|$stop|$($titleNode.InnerText)"
      if (-not $dedupe.Add($key)) { continue }
      [void]$tv.AppendChild($output.ImportNode($node, $true))
      $counts[$id]++
    }
  }
  # Tolerancia general: un canal sin datos nuevos no bloquea los demas.
  # Recuperar solo programacion no caducada del XMLTV anterior, si existe.
  $nowUTC = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
  $previous = $null
  if (Test-Path $dest) {
    try { [xml]$previous = Get-Content $dest -Raw -Encoding UTF8 }
    catch { Write-Warning 'La EPG anterior no es XML valido; no se reutilizara.' }
  }
  if ($null -eq $previous) {
    $publicada = Join-Path $stage 'epg-publicada-anterior.xml'
    try {
      Invoke-WebRequest -Uri 'https://ahmedhdadou-star.github.io/epg-personalizada/epg-total.xml' -OutFile $publicada -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
      [xml]$copia = Get-Content $publicada -Raw -Encoding UTF8
      if ($copia.DocumentElement.LocalName -ne 'tv' -or @($copia.SelectNodes('/tv/programme')).Count -lt 100) {
        throw 'El respaldo publicado no contiene XMLTV valido suficiente.'
      }
      $previous = $copia
      Write-Host 'Respaldo XMLTV publicado recuperado para canales sin programas.' -ForegroundColor Yellow
    } catch {
      Write-Warning "No se pudo recuperar el respaldo publicado: $($_.Exception.Message)"
    }
  }
  # El XMLTV publicado adapta ciertos IDs a los identificadores M3U.
  $idsPublicados = @{
    'AlAoula.ma' = 'alaoula.ae'
    '2M.ma' = '2mmaroc.es'
    'MBC1.ae' = 'mbc1.ae'
    'RotanaCinemaEgypt.eg' = 'rotanacinemaegypt.ae'
  }
  function Id-Anterior([string]$id) {
    if ($null -ne $previous -and $idsPublicados.ContainsKey($id) -and
        $null -ne $previous.SelectSingleNode("/tv/channel[@id='$($idsPublicados[$id])']")) {
      return $idsPublicados[$id]
    }
    return $id
  }
  foreach ($id in $priority.Keys) {
    if (-not $channels.ContainsKey($id)) {
      $idRespaldo = Id-Anterior $id
      $oldChannel = if ($null -ne $previous) { $previous.SelectSingleNode("/tv/channel[@id='$idRespaldo']") } else { $null }
      if ($null -ne $oldChannel) {
        $importado = $output.ImportNode($oldChannel, $true)
        $importado.SetAttribute('id', $id)
        [void]$tv.AppendChild($importado)
      } else {
        $fallback = $output.CreateElement('channel')
        $fallback.SetAttribute('id', $id)
        $display = $output.CreateElement('display-name')
        $display.InnerText = $id
        [void]$fallback.AppendChild($display)
        [void]$tv.AppendChild($fallback)
      }
      $channels[$id] = $true
      $counts[$id] = 0
    }
    if ($counts[$id] -eq 0 -and $null -ne $previous) {
      $idRespaldo = Id-Anterior $id
      foreach ($old in $previous.SelectNodes("/tv/programme[@channel='$idRespaldo']")) {
        $titleNode = $old.SelectSingleNode('title')
        $startTime = $old.GetAttribute('start')
        $endTime = $old.GetAttribute('stop')
        if (-not $endTime) { $endTime = $startTime }
        if ($null -eq $titleNode -or $startTime.Length -lt 14 -or $endTime.Length -lt 14) { continue }
        if ($endTime.Substring(0,14) -lt $nowUTC) { continue }
        $key = "$id|$startTime|$($old.GetAttribute('stop'))|$($titleNode.InnerText)"
        if ($dedupe.Add($key)) {
          $importado = $output.ImportNode($old, $true)
          $importado.SetAttribute('channel', $id)
          [void]$tv.AppendChild($importado)
          $counts[$id]++
        }
      }
    }
    if ($counts[$id] -eq 0) {
      Write-Warning "${id}: sin EPG vigente; se mantiene el canal sin inventar programas."
    }
  }
  # Evitar publicar una guia global casi vacia si fallan numerosas fuentes.
  $totalProgramas = @($tv.SelectNodes('/tv/programme')).Count
  $canalesConDatos = @($priority.Keys | Where-Object { $counts[$_] -gt 0 }).Count
  if ($totalProgramas -lt 100 -or $canalesConDatos -lt 10) {
    throw "EPG insuficiente: $totalProgramas programas en $canalesConDatos canales (minimo: 100 programas y 10 canales)."
  }
  # Escribir y verificar en staging. Solo sustituir el archivo final si todo sale bien.
  $candidate = Join-Path $stage 'epg-arabe.xml'
  $settings = New-Object System.Xml.XmlWriterSettings
  $settings.Indent = $true
  $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
  $writer = [System.Xml.XmlWriter]::Create($candidate, $settings)
  try { $output.Save($writer) } finally { $writer.Dispose() }
  [xml]$check = Get-Content $candidate -Raw -Encoding UTF8
  if (@($check.SelectNodes('/tv/channel')).Count -ne 38) {
    throw 'Error de validacion: se esperaban 38 canales.'
  }
  $backup = Join-Path $base 'epg-arabe-anterior.xml'
  if (Test-Path $dest) { Copy-Item $dest $backup -Force }
  Copy-Item $candidate $dest -Force
  $total = @($check.SelectNodes('/tv/programme')).Count
  $status = "OK $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - 38 canales, $total programas; $canalesConDatos canales con programacion. Los canales vacios no bloquean la publicacion."
  Add-Content $log $status -Encoding UTF8
  Write-Host "`n$status" -ForegroundColor Green
  Write-Host "Resultado: $dest"
  Write-Host "Copia anterior: $backup"
}
catch {
  $msg = "ERROR $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $($_.Exception.Message)"
  Add-Content $log $msg -Encoding UTF8
  Write-Error "$msg. No se ha sustituido el XMLTV valido anterior."
  exit 1
}
