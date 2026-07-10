# Lee el wiring REALMENTE desplegado de un site del legado (el valor real solo vive en el guest, no en el repo).
# Corre EN el guest (via SSH). Imprime pares clave=valor, una linea por clave. Las passwords se enmascaran.
#
# Con -Slot N lee el arbol del slot (C:\wt<N>); sin el, el arbol singleton (C:\src).
param(
  [int]$Slot   = -1,
  [string]$App = ""
)
$ErrorActionPreference = "Stop"

if ($App -eq "") {
  if ($Slot -ge 0) { $App = "C:\wt$Slot\CargaPlantaPT_LN\ProgramaMaestroPT" }
  else             { $App = "C:\src\CargaPlantaPT_LN\ProgramaMaestroPT" }
}

"app=$App"
if (-not (Test-Path $App)) { "error=arbol ausente"; exit 0 }

$cfgPath = Join-Path $App "Web.config"
if (Test-Path $cfgPath) {
  [xml]$cfg = Get-Content $cfgPath
  # GetAttribute, no $n.value: la propiedad .Value de XmlElement gana sobre el atributo homonimo y devuelve $null.
  foreach ($k in @('conStringOracle', 'backendBaseUrl')) {
    $n = $cfg.SelectSingleNode("//appSettings/add[@key='$k']")
    if ($n) { "$k=" + $n.GetAttribute('value') } else { "$k=<ausente>" }
  }
  # Puerto y host del Oracle al que apunta el site: los consume la verificacion del wiring por slot.
  $n = $cfg.SelectSingleNode("//appSettings/add[@key='conStringOracle']")
  $ocs = if ($n) { $n.GetAttribute('value') } else { "" }
  if ($ocs -match '\(port=(\d+)\)') { "oraclePort=" + $Matches[1] } else { "oraclePort=<desconocido>" }
  if ($ocs -match '\(host=([^)]+)\)') { "oracleHost=" + $Matches[1] } else { "oracleHost=<desconocido>" }
} else { "error=Web.config ausente" }

$connCfg = Join-Path $App "Config\connections.config"
if (Test-Path $connCfg) {
  [xml]$conn = Get-Content $connCfg
  foreach ($add in $conn.SelectNodes("//connectionStrings/add")) {
    $name = $add.GetAttribute('name')
    if ($name -in @('ConStrPm', 'ConStrJobsReader', 'ConStrInforLN', 'ConStrMicroservicio')) {
      # Enmascara la password; el resto de la cadena es lo que interesa verificar.
      $v = [regex]::Replace($add.GetAttribute('connectionString'), '(?i)(password=)[^;]*', '${1}***')
      "$name=$v"
    }
  }
} else { "error=connections.config ausente" }
