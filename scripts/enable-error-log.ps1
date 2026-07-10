# Habilita un log de errores DETALLADO para el legado, SIN tocar el repo (edita el Web.config DESPLEGADO).
# El legado captura todo en Application_Error y redirige a ErrorPage con solo el mensaje (sin stack).
# Para no perder el detalle se activa ASP.NET Health Monitoring -> Windows Application Event Log, que
# registra cada excepcion no controlada con stack trace completo + URL, aunque la app redirija.
# Ademas customErrors=Off (detalle en respuestas que no pasen por el redirect). Recicla el pool del slot.
#
# -Slot N deriva App y Pool del slot (arbol C:\wt<N>, pool pm-wt<N>); sin -Slot opera la via singleton.
# -ClearEventLog es opt-in: el Application Event Log es COMPARTIDO por toda la VM, y limpiarlo borraria la
# evidencia de los demas slots y sesiones.
param(
  [int]$Slot    = -1,
  [string]$App  = "",
  [string]$Pool = "",
  [switch]$ClearEventLog
)
$ErrorActionPreference = "Stop"
Import-Module WebAdministration

if ($Slot -ge 0) {
  if ($App -eq "")  { $App  = "C:\wt$Slot\CargaPlantaPT_LN\ProgramaMaestroPT" }
  if ($Pool -eq "") { $Pool = "pm-wt$Slot" }
} else {
  if ($App -eq "")  { $App  = "C:\src\CargaPlantaPT_LN\ProgramaMaestroPT" }
  if ($Pool -eq "") { $Pool = "pm" }
}

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

# El Application Event Log es compartido por toda la VM: limpiarlo borra la evidencia de los demas sites.
if ($ClearEventLog) {
  try { Clear-EventLog -LogName Application -ErrorAction Stop; "Application Event Log limpiado (compartido por toda la VM)" }
  catch { Write-Warning "no se pudo limpiar el Event Log: $($_.Exception.Message)" }
} else {
  "Application Event Log conservado (compartido; -ClearEventLog para limpiarlo)"
}

Restart-WebAppPool -Name $Pool
"app pool '$Pool' reciclado. Diagnostico activo desde: $(Get-Date -Format s)"
"Leer errores:  Get-WinEvent -LogName Application -MaxEvents 50 | ? { `$_.ProviderName -like 'ASP.NET*' }"
