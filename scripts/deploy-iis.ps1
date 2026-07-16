# Publica el web project legacy en IIS (app pool .NET v4.0 integrado). Corre EN el guest (via SSH).
# - Raiz del site: carpeta minima con health.aspx (smoke ASP.NET, sin BD).
# - La app se publica como Application IIS bajo el vdir que el legado espera (rutas absolutas /ProgramaMaestroLN/).
# - Inyecta el connection string del data tier local en el Web.config DESPLEGADO (la frontera: el repo legado
#   conserva los valores de PROD; el wrapper inyecta los de dev aqui, en el guest).
#
# Aislamiento por slot (-Slot N): site y pool 'pm-wt<N>', arbol C:\wt<N>\CargaPlantaPT_LN, raiz
# C:\inetpub\pmroot-wt<N>, binding 8100+N. El vdir es SIEMPRE 'ProgramaMaestroLN' (el legado hardcodea la raiz
# virtual absoluta /ProgramaMaestroLN/): el aislamiento lo da el site, nunca el vdir. Sin -Slot conserva la via
# singleton ('pm':8080, arbol C:\src).
param(
  [int]$Slot        = -1,
  [int]$Port        = 0,
  [string]$App      = "",
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
  [string]$SqlReaderPassB64  = "",
  # ConStrInforLN (backlog LN): catalogo del proxy SQL del backlog LN. Es un singleton COMPARTIDO entre slots
  # (pm_erpln106, no derivado del slot), en el MISMO SQL compartido y con las mismas credenciales que ConStrPm;
  # por eso viaja como constante con default y no en base64 (sin caracteres que rompan el quoting via SSH).
  [string]$SqlInforLnDb      = "pm_erpln106"
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

# --- Derivacion por slot. Un parametro explicito (-App / -Port) gana sobre el derivado. ---
if ($Slot -ge 0) {
  $SiteName = "pm-wt$Slot"
  $root     = "C:\inetpub\pmroot-wt$Slot"
  if ($App -eq "") { $App  = "C:\wt$Slot\CargaPlantaPT_LN\ProgramaMaestroPT" }
  if ($Port -eq 0) { $Port = 8100 + $Slot }
} else {
  $SiteName = "pm"
  $root     = "C:\inetpub\pmroot"
  if ($App -eq "") { $App  = "C:\src\CargaPlantaPT_LN\ProgramaMaestroPT" }
  if ($Port -eq 0) { $Port = 8080 }
}

# WCF Services > HTTP Activation: sin este feature IIS no registra el handler *.svc y TODAS las
# llamadas WCF (WCFobtenerDatos.svc/*) dan 404 -> la capa de datos AJAX del legado no funciona.
# Es machine-wide: un solo guard sirve a todos los sites.
if (-not (Get-WindowsFeature -Name NET-WCF-HTTP-Activation45 -ErrorAction SilentlyContinue).Installed) {
  Install-WindowsFeature -Name NET-WCF-HTTP-Activation45 | Out-Null
  "WCF HTTP Activation instalado (handler *.svc)"
}

# --- F4: repunta conStringOracle al data tier (ControlPiso) en el Web.config desplegado ---
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

# --- E2E: inyecta ConStrPm/ConStrJobsReader/ConStrInforLN (connectionStrings via configSource) en el
# Config\connections.config DESPLEGADO. El repo versiona placeholders (__SQL_PM_*__ para el backend PM;
# __SQL_INFOR_LN_HOST__ para el backlog LN; sin credenciales ni host); el valor real solo vive aqui, en el guest.
# ConStrInforLN apunta al proxy SQL del backlog LN (pm_erpln106), en el MISMO SQL compartido y con las mismas
# credenciales que ConStrPm, para que el camino OFF/InforLN del legado lea el backlog en el slot. La reescritura
# del catalogo se acota POR NOMBRE de cadena: NO se toca ConStrMicroservicio (Nucleos) ni las cadenas de
# SecurePerfect, que comparten los placeholders __SQL_USER__/__SQL_PASSWORD__ con ConStrInforLN. ---
if ($SqlPmHost -ne "") {
  $connCfg = Join-Path $App "Config\connections.config"
  if (Test-Path $connCfg) {
    # ConStrJobsReader usa el login de solo-lectura pm_reader; sin credenciales de lector cae al login de la
    # app (mismo patron que ConStrPm) para no dejar el placeholder sin resolver.
    $rdUser = if ($SqlReaderUser -ne "") { $SqlReaderUser } else { $SqlPmUser }
    $rdPass = if ($SqlReaderPass -ne "") { $SqlReaderPass } else { $SqlPmPass }

    $connXml = New-Object System.Xml.XmlDocument
    $connXml.PreserveWhitespace = $true
    $connXml.Load($connCfg)
    $pmNames = @('ConStrPm', 'ConStrJobsReader')
    foreach ($add in $connXml.SelectNodes("//connectionStrings/add")) {
      # GetAttribute, no $add.name: la propiedad .Name de XmlElement gana sobre el atributo homonimo.
      $name = $add.GetAttribute('name')
      $v    = $add.GetAttribute('connectionString')
      $v = $v.Replace('__SQL_PM_HOST__', $SqlPmHost)
      $v = $v.Replace('__SQL_PM_USER__', $SqlPmUser)
      $v = $v.Replace('__SQL_PM_PASSWORD__', $SqlPmPass)
      $v = $v.Replace('__SQL_PM_READER_USER__', $rdUser)
      $v = $v.Replace('__SQL_PM_READER_PASSWORD__', $rdPass)
      # Un redeploy sobre un config ya reescrito no encuentra el literal 'pm_planning;', pero si el catalogo del
      # slot anterior: el regex re-apunta el catalogo cuantas veces se redeploye (idempotente por slot).
      if ($SqlPmDb -ne "" -and $pmNames -contains $name) {
        $v = [regex]::Replace($v, 'Initial Catalog=[^;]*;', 'Initial Catalog=' + $SqlPmDb + ';')
      }
      # ConStrInforLN: reusa host/credenciales de ConStrPm (mismo SQL compartido) y re-apunta el catalogo al proxy
      # LN del slot (pm_erpln106). El reemplazo de __SQL_USER__/__SQL_PASSWORD__ se ACOTA a este nodo (nunca global)
      # porque esos placeholders tambien viven en ConStrMicroservicio/SecurePerfect. Idempotente: el redeploy
      # re-apunta el catalogo (placeholder 'erpln106' o el valor de una corrida previa).
      if ($name -eq 'ConStrInforLN') {
        $v = $v.Replace('__SQL_INFOR_LN_HOST__', $SqlPmHost)
        $v = $v.Replace('__SQL_USER__', $SqlPmUser)
        $v = $v.Replace('__SQL_PASSWORD__', $SqlPmPass)
        if ($SqlInforLnDb -ne "") {
          $v = [regex]::Replace($v, 'Initial Catalog=[^;]*;', 'Initial Catalog=' + $SqlInforLnDb + ';')
        }
      }
      $add.SetAttribute('connectionString', $v)
    }
    $connXml.Save($connCfg)
    "ConStrPm -> Server=$SqlPmHost; Catalog=$SqlPmDb; User=$SqlPmUser"
    "ConStrJobsReader -> Server=$SqlPmHost; Catalog=$SqlPmDb; User=$rdUser"
    "ConStrInforLN -> Server=$SqlPmHost; Catalog=$SqlInforLnDb; User=$SqlPmUser"
  } else { Write-Warning "Config\connections.config no encontrado en $App (fuente legacy sin connectionStrings externalizado; ConStrPm sin inyectar)" }
}

# --- Raiz del site: carpeta minima con health.aspx (smoke sin BD) ---
New-Item -ItemType Directory -Force -Path $root | Out-Null
$health = '<%@ Page Language="C#" %><% Response.Write("PMHOST OK CLR=" + System.Environment.Version.ToString() + " host=" + System.Environment.MachineName); %>'
Set-Content -Path (Join-Path $root "health.aspx") -Value $health -Encoding ascii

# --- App pool ---
if (Test-Path "IIS:\AppPools\$SiteName") { Remove-WebAppPool $SiteName }
New-WebAppPool $SiteName | Out-Null
Set-ItemProperty "IIS:\AppPools\$SiteName" managedRuntimeVersion v4.0
Set-ItemProperty "IIS:\AppPools\$SiteName" managedPipelineMode Integrated

# --- Site (raiz = health) + Application bajo el vdir que la app espera ---
if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
New-Website -Name $SiteName -Port $Port -PhysicalPath $root -ApplicationPool $SiteName -Force | Out-Null
New-WebApplication -Site $SiteName -Name $Vdir -PhysicalPath $App -ApplicationPool $SiteName | Out-Null
Start-Website -Name $SiteName -ErrorAction SilentlyContinue

# --- Firewall: el binding no basta. El 8080 del singleton se abrio por fuera de estos scripts, asi que un site
# nuevo no hereda regla alguna y el health desde macdata daria timeout. Idempotente por nombre de regla. ---
$ruleName = "PM site $SiteName"
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
  Set-NetFirewallRule -DisplayName $ruleName -Enabled True -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  "regla de firewall '$ruleName' actualizada (TCP $Port)"
} else {
  New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  "regla de firewall '$ruleName' creada (TCP $Port)"
}

"bin dll count: " + (Get-ChildItem (Join-Path $App 'bin') -Filter *.dll -ErrorAction SilentlyContinue | Measure-Object).Count
"site '$SiteName' @ :$Port   root -> $root   app /$Vdir -> $App"
