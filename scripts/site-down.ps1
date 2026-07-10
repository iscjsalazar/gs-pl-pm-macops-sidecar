# Desmonta el frontend per-slot del legado en IIS. Corre EN el guest (via SSH).
# Quirurgico: todos los artefactos derivan de $Slot (site/pool pm-wt<N>, arbol C:\wt<N>, raiz
# C:\inetpub\pmroot-wt<N>). El site singleton 'pm' y los demas slots quedan intactos.
# Idempotente: cada paso tolera la ausencia del artefacto.
param(
  [Parameter(Mandatory = $true)]
  [ValidateRange(0, 99)]
  [int]$Slot
)
$ErrorActionPreference = "Continue"
Import-Module WebAdministration

$site = "pm-wt$Slot"

if (Get-Website -Name $site -ErrorAction SilentlyContinue) {
  Stop-Website -Name $site -ErrorAction SilentlyContinue
  Remove-Website -Name $site
  "site $site removido"
} else { "site $site ausente" }

if (Test-Path "IIS:\AppPools\$site") { Remove-WebAppPool $site; "pool $site removido" } else { "pool $site ausente" }

foreach ($p in @("C:\wt$Slot", "C:\inetpub\pmroot-wt$Slot", "C:\aspnettemp\wt$Slot")) {
  if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; "removido $p" }
}
# Este script se ejecuta desde C:\site-down-wt<N>.ps1: no se autoborra (lo recicla el siguiente scp).
foreach ($f in @("C:\src-wt$Slot.zip", "C:\deploy-iis-wt$Slot.ps1", "C:\enable-error-log-wt$Slot.ps1")) {
  if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue; "removido $f" }
}

$rule = Get-NetFirewallRule -DisplayName "PM site $site" -ErrorAction SilentlyContinue
if ($rule) { $rule | Remove-NetFirewallRule; "regla de firewall 'PM site $site' removida" } else { "regla de firewall 'PM site $site' ausente" }

"slot $Slot desmontado"
