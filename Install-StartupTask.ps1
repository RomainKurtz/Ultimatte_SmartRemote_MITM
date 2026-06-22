<#
.SYNOPSIS
    Cree (ou met a jour) une tache planifiee qui lance hub4com + Switch-Bridge AU DEMARRAGE,
    SANS aucune fenetre. A executer UNE SEULE FOIS, dans un PowerShell "Administrateur".

    La tache :
      - se declenche au demarrage de Windows (avec un delai, le temps que l'USB-serie soit pret) ;
      - s'execute en compte SYSTEM, "que l'utilisateur soit connecte ou non" => aucune fenetre ;
      - "droits les plus eleves" => l'ecoute HTTP reseau (http://+:port) fonctionne ;
      - sans limite de duree, redemarre en cas d'echec.
    Ouvre aussi le port HTTP dans le PARE-FEU Windows (regle entrante TCP), indispensable pour
    y acceder depuis un AUTRE ordinateur du reseau.

.PARAMETER TaskName   Nom de la tache. Defaut 'UltimatteKeyBridge'.
.PARAMETER StartDelay Delai apres le boot avant de lancer (format ISO8601). Defaut 'PT30S' (30 s).
.PARAMETER HttpPort   Port HTTP transmis au lanceur. Defaut 8088.
.PARAMETER NotifyUrl       URL de base notifiee (POST) sur changement d'unite MANUEL. Ex Companion :
                           'http://127.0.0.1:8000'. Requiert aussi -NotifyVariable.
.PARAMETER NotifyVariable  Nom de la variable personnalisee Companion a mettre a jour (ex 'ultimatte_unit').
.PARAMETER Restart    Apres l'enregistrement : ARRETE l'instance en cours puis la REDEMARRE,
                      afin d'APPLIQUER TOUT DE SUITE le nouveau port (sans rebooter).
.PARAMETER Remove     Supprime la tache au lieu de la creer.

.EXAMPLE
    # Installer (clic droit PowerShell -> Executer en tant qu'administrateur) :
    .\Install-StartupTask.ps1

.EXAMPLE
    # Changer de port ET l'appliquer immediatement (arrete + relance la tache) :
    .\Install-StartupTask.ps1 -HttpPort 9000 -Restart

.EXAMPLE
    # Notifier Companion (variable 'ultimatte_unit') sur appui MANUEL, et appliquer tout de suite :
    .\Install-StartupTask.ps1 -NotifyUrl 'http://127.0.0.1:8000' -NotifyVariable 'ultimatte_unit' -Restart

.EXAMPLE
    # Desinstaller :
    .\Install-StartupTask.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'UltimatteKeyBridge',
    [string]$StartDelay = 'PT10S',
    [int]$HttpPort = 8088,
    [string]$NotifyUrl,
    [string]$NotifyVariable,
    [switch]$Restart,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$fwName = "$TaskName-HTTP"   # nom de la regle de pare-feu associee

# Verifier les droits administrateur
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Lance ce script dans un PowerShell ADMINISTRATEUR (clic droit -> Executer en tant qu'administrateur)."
    return
}

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Tache '$TaskName' supprimee." -ForegroundColor Green
    }
    else {
        Write-Host "Tache '$TaskName' inexistante." -ForegroundColor Yellow
    }
    if (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
        Write-Host "Regle de pare-feu '$fwName' supprimee." -ForegroundColor Green
    }
    return
}

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$launcher = Join-Path $here 'Start-Bridge-AtBoot.ps1'
if (-not (Test-Path $launcher)) { Write-Error "Introuvable : $launcher"; return }

# Arreter une eventuelle instance en cours AVANT de reenregistrer (sinon elle garde l'ancien port,
# et MultipleInstances=IgnoreNew empeche un nouveau demarrage tant qu'elle tourne).
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Tache existante : arret de l'instance en cours..." -ForegroundColor DarkYellow
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process -Name 'hub4com' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

$argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -HttpPort {1}' -f $launcher, $HttpPort
if ($NotifyUrl -and $NotifyVariable) {
    $argument += ' -NotifyUrl "{0}" -NotifyVariable "{1}"' -f $NotifyUrl, $NotifyVariable
}

$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argument -WorkingDirectory $here

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = $StartDelay

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description 'Demarre hub4com + Switch-Bridge (injection HTTP Ultimatte) au boot, sans fenetre.' -Force | Out-Null

$registered = (Get-ScheduledTask -TaskName $TaskName).Actions.Arguments

# Ouvrir le port dans le pare-feu Windows (sinon : accessible en localhost mais PAS depuis le reseau).
# On remplace l'ancienne regle (le port a pu changer).
if (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue
}
New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $HttpPort -Profile Any -Description "Acces HTTP au pont Ultimatte (Switch-Bridge)." | Out-Null
Write-Host ("Regle de pare-feu '{0}' : autorise TCP entrant sur le port {1} (tous profils)." -f $fwName, $HttpPort) -ForegroundColor Green

Write-Host "Tache '$TaskName' installee." -ForegroundColor Green
Write-Host ("  Lanceur   : {0}" -f $launcher) -ForegroundColor DarkGray
Write-Host ("  HTTP      : port {0}" -f $HttpPort) -ForegroundColor DarkGray
Write-Host ("  Delai     : {0} apres le boot" -f $StartDelay) -ForegroundColor DarkGray
Write-Host ("  Argument enregistre : {0}" -f $registered) -ForegroundColor DarkGray

if ($Restart) {
    Write-Host "`nApplication immediate : redemarrage de la tache..." -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process -Name 'hub4com' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Tache redemarree sur le port $HttpPort." -ForegroundColor Green
}
else {
    Write-Host "`nPour APPLIQUER MAINTENANT (sans rebooter) :" -ForegroundColor Cyan
    Write-Host ("  .\Install-StartupTask.ps1 -HttpPort {0} -Restart" -f $HttpPort) -ForegroundColor Gray
    Write-Host "  (ou) Stop-ScheduledTask -TaskName '$TaskName' ; Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Suivre le journal :" -ForegroundColor Cyan
Write-Host ("  Get-Content '{0}' -Wait" -f (Join-Path $here 'bridge-boot.log')) -ForegroundColor Gray
Write-Host "Verifier l'ecoute :" -ForegroundColor Cyan
Write-Host ("  Get-NetTCPConnection -LocalPort {0} -State Listen" -f $HttpPort) -ForegroundColor Gray
Write-Host ("  Invoke-RestMethod http://localhost:{0}/unit/3" -f $HttpPort) -ForegroundColor Gray
