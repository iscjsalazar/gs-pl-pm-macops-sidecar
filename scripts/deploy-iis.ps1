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
  [string]$OraclePass = "ctrlpiso"
)
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

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
