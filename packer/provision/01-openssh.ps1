# Provisioner: habilita OpenSSH Server en Windows Server 2022 Core (para operar todo por SSH post-build).
$ErrorActionPreference = "Stop"
Write-Host "[provision] Instalando OpenSSH.Server ..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null

Write-Host "[provision] Habilitando y arrancando sshd ..."
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# PowerShell como shell por defecto de SSH (para los runners remotos).
$ps = (Get-Command powershell.exe).Source
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $ps -PropertyType String -Force | Out-Null

# Regla de firewall para SSH (por si la capability no la creó).
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Host "[provision] OpenSSH listo. sshd status:"
Get-Service sshd | Format-Table -AutoSize
Write-Host "[provision] OK"
