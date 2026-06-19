# Instala VS Build Tools 2022 en el guest: Roslyn (C# 6+), targeting packs .NET FW, y Microsoft.WebApplication.targets.
# Pensado para correr como tarea programada SYSTEM (detached). Marca C:\buildtools.DONE al terminar.
$ErrorActionPreference = "Continue"
$log = "C:\buildtools-install.log"
function L($m){ ("{0} {1}" -f (Get-Date -Format o), $m) | Tee-Object -FilePath $log -Append | Out-Null }
Remove-Item C:\buildtools.DONE -ErrorAction SilentlyContinue

L "download bootstrapper"
$o = "C:\vs_buildtools.exe"
try { Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $o -UseBasicParsing } catch { L "download ERR: $($_.Exception.Message)" }
L ("bootstrapper bytes: " + (Get-Item $o -ErrorAction SilentlyContinue).Length)

$args = @(
  '--quiet','--wait','--norestart','--nocache',
  '--add','Microsoft.VisualStudio.Workload.MSBuildTools',
  '--add','Microsoft.VisualStudio.Workload.WebBuildTools',
  '--add','Microsoft.Net.Component.4.8.SDK',
  '--add','Microsoft.Net.Component.4.8.TargetingPack',
  '--add','Microsoft.Net.Component.4.TargetingPack'
)
L "run installer"
$p = Start-Process -FilePath $o -ArgumentList $args -Wait -PassThru
L ("installer exit: " + $p.ExitCode)

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$mb = $null
if (Test-Path $vswhere) {
  $mb = & $vswhere -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
  L ("msbuild: " + $mb)
  if ($mb) { Set-Content C:\buildtools.msbuildpath $mb -Encoding ascii }
}
("exit={0};msbuild={1}" -f $p.ExitCode, $mb) | Set-Content C:\buildtools.DONE -Encoding ascii
L "DONE"
