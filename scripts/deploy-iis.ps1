# Publica el web project legacy en IIS (app pool .NET v4.0 integrado). Corre EN el guest (via SSH).
# - Raiz del site: carpeta minima con health.aspx (smoke ASP.NET, sin BD).
# - La app se publica como Application IIS bajo el vdir que el legado espera (rutas absolutas /ProgramaMaestroLN/).
# - Inyecta el connection string del data tier local en el Web.config DESPLEGADO (la frontera: el repo legado
#   conserva los valores de PROD; el wrapper inyecta los de dev aqui, en el guest).
param(
  [int]$Port        = 8080,
  [string]$App      = "C:\src\CargaPlantaPT_LN\ProgramaMaestroPT",
  [string]$Vdir     = "ProgramaMaestroLN",
  [string]$OracleHost = "172.16.128.1",
  [int]$OraclePort  = 1521,
  [string]$OracleSid  = "XE",
  [string]$OracleUser = "pge_ctrlpiso",
  [string]$OraclePass = "ctrlpiso",
  # --- E2E (solicitud e2e-launch-orchestration): wiring opcional al backend .NET 10. Los valores viajan en
  # base64 para evitar el quoting a traves de SSH -> PowerShell del guest. Vacio = no inyecta (legacy-launch
  # standalone conserva el comportamiento previo: solo repunta conStringOracle). ---
  [string]$BackendBaseUrlB64 = "",
  [string]$SqlPmHostB64      = "",
  [string]$SqlPmDbB64        = "",
  [string]$SqlPmUserB64      = "",
  [string]$SqlPmPassB64      = "",
  [string]$SqlReaderUserB64  = "",
  [string]$SqlReaderPassB64  = ""
)
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

# Decodifica los parametros E2E (base64 -> UTF8). Una cadena vacia queda vacia (no inyecta).
function FromB64([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return "" }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
$BackendBaseUrl = FromB64 $BackendBaseUrlB64
$SqlPmHost      = FromB64 $SqlPmHostB64
$SqlPmDb        = FromB64 $SqlPmDbB64
$SqlPmUser      = FromB64 $SqlPmUserB64
$SqlPmPass      = FromB64 $SqlPmPassB64
$SqlReaderUser  = FromB64 $SqlReaderUserB64
$SqlReaderPass  = FromB64 $SqlReaderPassB64

# WCF Services > HTTP Activation: sin este feature IIS no registra el handler *.svc y TODAS las
# llamadas WCF (WCFobtenerDatos.svc/*) dan 404 -> la capa de datos AJAX del legado no funciona.
if (-not (Get-WindowsFeature -Name NET-WCF-HTTP-Activation45 -ErrorAction SilentlyContinue).Installed) {
  Install-WindowsFeature -Name NET-WCF-HTTP-Activation45 | Out-Null
  "WCF HTTP Activation instalado (handler *.svc)"
}

# --- F4: repunta conStringOracle al data tier local (ControlPiso) en el Web.config desplegado ---
$cfgPath = Join-Path $App "Web.config"
[xml]$cfg = Get-Content $cfgPath
$cs = "data source=(description=(address=(protocol=tcp)(host=$OracleHost)(port=$OraclePort))(connect_data=(sid=$OracleSid)));user id=$OracleUser;password=$OraclePass;"
$node = $cfg.SelectSingleNode("//appSettings/add[@key='conStringOracle']")
if ($node) { $node.SetAttribute('value', $cs); $cfg.Save($cfgPath); "conStringOracle -> host=$OracleHost port=$OraclePort sid=$OracleSid user=$OracleUser" }
else { Write-Warning "appSettings/conStringOracle no encontrado en $cfgPath (no se repunta)" }

# --- E2E: inyecta backendBaseUrl (appSettings) en el Web.config desplegado (mismo patron que conStringOracle).
# El guest ve el backend por la pasarela NAT (p.ej. http://172.16.128.1:5180). ---
if ($BackendBaseUrl -ne "") {
  $bn = $cfg.SelectSingleNode("//appSettings/add[@key='backendBaseUrl']")
  if ($bn) { $bn.SetAttribute('value', $BackendBaseUrl); $cfg.Save($cfgPath); "backendBaseUrl -> $BackendBaseUrl" }
  else { Write-Warning "appSettings/backendBaseUrl no encontrado en $cfgPath (fuente legacy sin el wiring de Fase 1; sin inyectar)" }
}

# --- E2E: inyecta ConStrPm (connectionStrings via configSource) por reemplazo de tokens en el
# Config\connections.config DESPLEGADO. El repo versiona placeholders __SQL_PM_*__ (sin credenciales ni host);
# el valor real solo vive aqui, en el guest. El catalogo se sobreescribe para la ruta wt (pm_planning_wt<N>). ---
if ($SqlPmHost -ne "") {
  $connCfg = Join-Path $App "Config\connections.config"
  if (Test-Path $connCfg) {
    $txt = [System.IO.File]::ReadAllText($connCfg)
    $txt = $txt.Replace('__SQL_PM_HOST__', $SqlPmHost)
    $txt = $txt.Replace('__SQL_PM_USER__', $SqlPmUser)
    $txt = $txt.Replace('__SQL_PM_PASSWORD__', $SqlPmPass)
    # ConStrJobsReader (login de solo-lectura pm_reader; lectura del estado de jobs por SQL directo). Si no se
    # proveen credenciales de lector, cae al login de la app (mismo patron que ConStrPm) para no dejar el
    # placeholder sin resolver. Host y catalogo los comparte con ConStrPm (mismos tokens / mismo Initial Catalog).
    $rdUser = if ($SqlReaderUser -ne "") { $SqlReaderUser } else { $SqlPmUser }
    $rdPass = if ($SqlReaderPass -ne "") { $SqlReaderPass } else { $SqlPmPass }
    $txt = $txt.Replace('__SQL_PM_READER_USER__', $rdUser)
    $txt = $txt.Replace('__SQL_PM_READER_PASSWORD__', $rdPass)
    if ($SqlPmDb -ne "") { $txt = $txt.Replace('Initial Catalog=pm_planning;', "Initial Catalog=$SqlPmDb;") }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($connCfg, $txt, $enc)
    "ConStrPm -> Server=$SqlPmHost; Catalog=$SqlPmDb; User=$SqlPmUser"
    "ConStrJobsReader -> Server=$SqlPmHost; Catalog=$SqlPmDb; User=$rdUser"
  } else { Write-Warning "Config\connections.config no encontrado en $App (fuente legacy sin connectionStrings externalizado; ConStrPm sin inyectar)" }
}

# --- Raiz del site: carpeta minima con health.aspx (smoke sin BD) ---
$root = "C:\inetpub\pmroot"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$health = '<%@ Page Language="C#" %><% Response.Write("PMHOST OK CLR=" + System.Environment.Version.ToString() + " host=" + System.Environment.MachineName); %>'
Set-Content -Path (Join-Path $root "health.aspx") -Value $health -Encoding ascii

# --- App pool ---
if (Test-Path IIS:\AppPools\pm) { Remove-WebAppPool pm }
New-WebAppPool pm | Out-Null
Set-ItemProperty IIS:\AppPools\pm managedRuntimeVersion v4.0
Set-ItemProperty IIS:\AppPools\pm managedPipelineMode Integrated

# --- Site (raiz = health) + Application bajo el vdir que la app espera ---
if (Get-Website -Name pm -ErrorAction SilentlyContinue) { Remove-Website -Name pm }
New-Website -Name pm -Port $Port -PhysicalPath $root -ApplicationPool pm -Force | Out-Null
New-WebApplication -Site pm -Name $Vdir -PhysicalPath $App -ApplicationPool pm | Out-Null
Start-Website -Name pm -ErrorAction SilentlyContinue

"bin dll count: " + (Get-ChildItem (Join-Path $App 'bin') -Filter *.dll -ErrorAction SilentlyContinue | Measure-Object).Count
"site 'pm' @ :$Port   root -> $root   app /$Vdir -> $App"
