# Instala OpenSSH.Server en el guest como SYSTEM (evita "Access is denied" de DISM sobre WinRM network-token).
# Se ejecuta por WinRM; registra una tarea programada SYSTEM que hace el Add-WindowsCapability con token completo.
$ErrorActionPreference = "Stop"

$inner = @'
$ErrorActionPreference = "Continue"
Start-Transcript -Path C:\prov-openssh.log -Append | Out-Null
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
$ps = (Get-Command powershell.exe).Source
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $ps -PropertyType String -Force
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}
Stop-Transcript | Out-Null
'@
Set-Content -Path C:\prov-openssh.ps1 -Value $inner -Encoding UTF8

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\prov-openssh.ps1'
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount
Register-ScheduledTask -TaskName 'prov-openssh' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'prov-openssh'

$n = 0
do { Start-Sleep -Seconds 5; $n++; $state = (Get-ScheduledTask -TaskName 'prov-openssh').State } while ($state -eq 'Running' -and $n -lt 60)
"task state: $state after $($n*5)s"
"LastTaskResult: $((Get-ScheduledTaskInfo -TaskName 'prov-openssh').LastTaskResult)"
"sshd: $((Get-Service sshd -ErrorAction SilentlyContinue).Status)"
"OpenSSH.Server: $((Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0).State)"
if (Test-Path C:\prov-openssh.log) { "--- log tail ---"; Get-Content C:\prov-openssh.log -Tail 12 }
