# Vuelca los errores ASP.NET (Health Monitoring) del Application Event Log del guest, con detalle completo
# (tipo de excepcion, mensaje, stack trace, URL del request). Corre EN el guest.
param([int]$Max = 40)
$ErrorActionPreference = "SilentlyContinue"
$evs = Get-WinEvent -LogName Application -MaxEvents 300 |
  Where-Object { $_.ProviderName -match 'ASP\.NET' -and $_.LevelDisplayName -in @('Error','Warning','Information') -and $_.Message -match 'Exception|Event code|error' }
if (-not $evs) { "(sin eventos ASP.NET en el Application Event Log; navega para reproducir y reintenta)"; return }
"total eventos ASP.NET: $($evs.Count) (mostrando hasta $Max)"
$evs | Select-Object -First $Max | ForEach-Object {
  "==================================================================="
  "FECHA: $($_.TimeCreated)   NIVEL: $($_.LevelDisplayName)   SRC: $($_.ProviderName)"
  "-------------------------------------------------------------------"
  $_.Message
  ""
}
