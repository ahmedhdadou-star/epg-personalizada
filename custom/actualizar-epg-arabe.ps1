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
      $key = "$id|$start|$stop|$($titleNode.InnerText)"
      if (-not $dedupe.Add($key)) { continue }
      [void]$tv.AppendChild($output.ImportNode($node, $true))
      $counts[$id]++
    }
  }
  # Una cadena temporalmente sin EPG no debe bloquear la actualizacion.
  # Para canales opcionales, recuperar solamente programas aun vigentes del XML previo.
  $optionalNames = @{
    'RotanaCinemaEgypt.eg' = 'Rotana Cinema Egypt'
    'AbuDhabiTV.ae' = 'Abu Dhabi TV'
    'EmiratesTV.ae' = 'Emirates TV'
    'ElWatania1.tn' = 'El Watania 1'
    'ElWatania2.tn' = 'El Watania 2'
  }
  $optionalIds = @($optionalNames.Keys)
  $nowUTC = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
  if (Test-Path $dest) {
    [xml]$previous = Get-Content $dest -Raw -Encoding UTF8
    foreach ($id in $optionalIds) {
      if (-not $channels.ContainsKey($id)) {
        $previousChannel = $previous.SelectSingleNode("/tv/channel[@id='$id']")
        if ($null -ne $previousChannel) {
          [void]$tv.AppendChild($output.ImportNode($previousChannel, $true))
        } else {
          $fallbackChannel = $output.CreateElement('channel')
          $fallbackChannel.SetAttribute('id', $id)
          $display = $output.CreateElement('display-name')
          $display.InnerText = $optionalNames[$id]
          [void]$fallbackChannel.AppendChild($display)
          [void]$tv.AppendChild($fallbackChannel)
        }
        $channels[$id] = $true
        $counts[$id] = 0
      }
      if ($counts[$id] -eq 0) {
        foreach ($old in $previous.SelectNodes("/tv/programme[@channel='$id']")) {
          $endTime = $old.GetAttribute('stop')
          if (-not $endTime) { $endTime = $old.GetAttribute('start') }
          if ($endTime.Length -ge 14 -and $endTime.Substring(0,14) -ge $nowUTC) {
            $start = $old.GetAttribute('start')
            $key = "$id|$start|$($old.GetAttribute('stop'))|$($old.SelectSingleNode('title').InnerText)"
            if ($dedupe.Add($key)) {
              [void]$tv.AppendChild($output.ImportNode($old, $true))
              $counts[$id]++
            }
          }
        }
      }
    }
  }
  foreach ($id in $optionalIds) {
    if (-not $channels.ContainsKey($id)) {
      $fallbackChannel = $output.CreateElement('channel')
      $fallbackChannel.SetAttribute('id', $id)
      $display = $output.CreateElement('display-name')
      $display.InnerText = $optionalNames[$id]
      [void]$fallbackChannel.AppendChild($display)
      [void]$tv.AppendChild($fallbackChannel)
      $channels[$id] = $true
      $counts[$id] = 0
    }
    if ($counts[$id] -eq 0) {
      Write-Warning "${id}: sin EPG actual; queda declarado sin inventar programas."
    }
  }
  $missing = @($priority.Keys | Where-Object {
    (-not $channels.ContainsKey($_) -or $counts[$_] -lt 1) -and ($_ -notin $optionalIds)
  })
  if ($missing.Count -gt 0) { throw "Canales obligatorios ausentes o vacios: $($missing -join ', ')" }
  # Los 5 canales activos de SNRT y 2M deben tener programas de hoy o posteriores.
  # Arryadia se permite desactualizado, siguiendo la decision del usuario.
  foreach ($id in (@($snrtIds | Where-Object { $_ -ne 'Arryadia.ma' }) + @('2M.ma') + $wanted)) {
    $hasUpcoming = $false
    foreach ($node in $tv.SelectNodes('/tv/programme')) {
      if ($node.GetAttribute('channel') -eq $id -and
          $node.GetAttribute('start').Substring(0,14) -ge $nowUTC) {
        $hasUpcoming = $true
        break
      }
    }
    if (-not $hasUpcoming -and $id -notin $optionalIds) { throw "Sin programacion actual o futura: $id" }
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
  $status = "OK $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - 38 canales, $total programas; Rotana Cinema Egypt, Emirates TV y El Watania 1/2 pueden estar vacios y Arryadia anticuada."
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

