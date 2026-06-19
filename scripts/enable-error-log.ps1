# Habilita un log de errores DETALLADO para el legado, SIN tocar el repo (edita el Web.config DESPLEGADO).
# El legado captura todo en Application_Error y redirige a ErrorPage con solo el mensaje (sin stack).
# Para no perder el detalle se activa ASP.NET Health Monitoring -> Windows Application Event Log, que
# registra cada excepcion no controlada con stack trace completo + URL, aunque la app redirija.
# Ademas customErrors=Off (detalle en respuestas que no pasen por el redirect). Recicla el pool y limpia el log.
param(
  [string]$App  = "C:\src\CargaPlantaPT_LN\ProgramaMaestroPT",
  [string]$Pool = "pm"
)
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

$cfgPath = Join-Path $App "Web.config"
[xml]$cfg = Get-Content $cfgPath
$sw = $cfg.SelectSingleNode("/configuration/system.web")

# customErrors = Off
$ce = $cfg.SelectSingleNode("/configuration/system.web/customErrors")
if (-not $ce) { $ce = $cfg.CreateElement("customErrors"); $sw.AppendChild($ce) | Out-Null }
$ce.SetAttribute("mode","Off")

# Health Monitoring -> Event Log (reemplaza si ya existe). Profile sin throttling (minInterval 0).
$old = $cfg.SelectSingleNode("/configuration/system.web/healthMonitoring")
if ($old) { $sw.RemoveChild($old) | Out-Null }
$hm = [xml]@"
<healthMonitoring enabled="true">
  <profiles>
    <add name="pmCritical" minInstances="1" maxLimit="Infinite" minInterval="00:00:00" />
  </profiles>
  <eventMappings>
    <add name="All Errors" type="System.Web.Management.WebBaseErrorEvent,System.Web,Version=4.0.0.0,Culture=neutral,PublicKeyToken=b03f5f7f11d50a3a" startEventCode="0" endEventCode="2147483647" />
  </eventMappings>
  <providers>
    <add name="EventLogProvider" type="System.Web.Management.EventLogWebEventProvider,System.Web,Version=4.0.0.0,Culture=neutral,PublicKeyToken=b03f5f7f11d50a3a" />
  </providers>
  <rules>
    <add name="All Errors -> EventLog" eventName="All Errors" provider="EventLogProvider" profile="pmCritical" minInterval="00:00:00" />
  </rules>
</healthMonitoring>
"@
$sw.AppendChild($cfg.ImportNode($hm.DocumentElement, $true)) | Out-Null
$cfg.Save($cfgPath)
"Web.config: customErrors=Off + healthMonitoring -> Event Log  ($cfgPath)"

# Limpia el Application Event Log (VM de dev dedicada) para arrancar con logs limpios.
try { Clear-EventLog -LogName Application -ErrorAction Stop; "Application Event Log limpiado" }
catch { Write-Warning "no se pudo limpiar el Event Log: $($_.Exception.Message)" }

Restart-WebAppPool -Name $Pool
"app pool '$Pool' reciclado. Logs limpios desde: $(Get-Date -Format s)"
"Leer errores:  Get-WinEvent -LogName Application -MaxEvents 50 | ? { `$_.ProviderName -like 'ASP.NET*' }"
