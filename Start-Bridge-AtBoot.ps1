<#
.SYNOPSIS
    Lanceur "au demarrage" (sans fenetre) : demarre hub4com (relais panneau<->logiciel +
    duplication vers COM2) PUIS Switch-Bridge.ps1 en mode injection HTTP.

    Concu pour etre appele par une tache planifiee (voir Install-StartupTask.ps1) configuree
    "Executer que l'utilisateur soit connecte ou non" -> aucune fenetre n'apparait.

    Comme il n'y a pas de fenetre, tout est journalise dans bridge-boot.log (a cote du script).

.PARAMETER Hub4com    Chemin de hub4com.exe. Si vide : auto-detection (a cote du script, dossier com0com).
.PARAMETER AppPort    Port com0com moniteur/injection (partenaire de COM2 cote hub4com). Defaut COM2.
.PARAMETER PanelPort  Port PHYSIQUE du panneau. Defaut COM5.
.PARAMETER HttpPort   Port du serveur HTTP d'injection. Defaut 8088.
.PARAMETER NotifyUrl       URL de base a notifier (POST) sur changement d'unite MANUEL. Ex : 'http://127.0.0.1:8000'.
.PARAMETER NotifyVariable  Nom de la variable personnalisee Companion a mettre a jour.
.PARAMETER WaitPortSeconds  Attend (max N s) que le port physique du panneau soit enumere. Defaut 90.

.EXAMPLE
    .\Start-Bridge-AtBoot.ps1
#>
[CmdletBinding()]
param(
    [string]$Hub4com,
    [string]$AppPort = 'COM2',
    [string]$PanelPort = 'COM5',
    [int]$HttpPort = 8088,
    [string]$NotifyUrl,
    [string]$NotifyVariable,
    [int]$WaitPortSeconds = 10
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$log = Join-Path $here 'bridge-boot.log'

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

Log "=== Demarrage du lanceur (au boot) ==="

# 1) Localiser hub4com.exe
if (-not $Hub4com) {
    $cands = @(
        (Join-Path $here 'hub4com.exe'),
        'C:\Program Files (x86)\com0com\hub4com.exe',
        'C:\Program Files\com0com\hub4com.exe'
    )
    $Hub4com = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Hub4com -or -not (Test-Path $Hub4com)) {
    Log "ERREUR : hub4com.exe introuvable. Passe -Hub4com 'C:\chemin\hub4com.exe'."
    exit 1
}
Log ("hub4com.exe : {0}" -f $Hub4com)

# 2) Attendre que le port physique du panneau soit present (USB-serie pret apres le boot)
$deadline = (Get-Date).AddSeconds($WaitPortSeconds)
$found = $false
while ((Get-Date) -lt $deadline) {
    if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $PanelPort) { $found = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $found) {
    Log ("AVERTISSEMENT : {0} non vu apres {1}s. On tente quand meme." -f $PanelPort, $WaitPortSeconds)
}
else {
    Log ("{0} present." -f $PanelPort)
}

# 3) Tuer un hub4com residuel (evite les doublons qui tiennent les ports), puis le relancer CACHE
$stale = Get-Process -Name 'hub4com' -ErrorAction SilentlyContinue
if ($stale) {
    Log ("hub4com deja present (PID {0}) : on l'arrete avant de relancer." -f ($stale.Id -join ','))
    $stale | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
$hubArgs = @(
    '--baud=115200', '--parity=odd', '--octs=off',
    '--route=0:1,2', '--route=1:0,2', '--route=2:1',
    ('\\.\' + $PanelPort), '\\.\CNCB0', '\\.\CNCB1'
)
Log ("Lancement hub4com : {0} {1}" -f $Hub4com, ($hubArgs -join ' '))
try {
    $hub = Start-Process -FilePath $Hub4com -ArgumentList $hubArgs -WindowStyle Hidden -PassThru
    Log ("hub4com demarre (PID {0})." -f $hub.Id)
}
catch {
    Log ("ERREUR au lancement de hub4com : {0}" -f $_.Exception.Message)
    exit 1
}

# Laisser hub4com ouvrir les ports avant d'attaquer le pont
Start-Sleep -Seconds 3

# 4) Lancer le pont (process AU PREMIER PLAN -> c'est lui que la tache "surveille").
#    Boucle infinie : si le pont s'arrete anormalement, on le relance.
$bridge = Join-Path $here 'Switch-Bridge.ps1'
if (-not (Test-Path $bridge)) { Log ("ERREUR : {0} introuvable." -f $bridge); exit 1 }

$bridgeArgs = @{ InjectOnly = $true; AppPort = $AppPort; PanelPort = $PanelPort; HttpPort = $HttpPort; LogFile = $log }
if ($NotifyUrl -and $NotifyVariable) { $bridgeArgs.NotifyUrl = $NotifyUrl; $bridgeArgs.NotifyVariable = $NotifyVariable }

while ($true) {
    Log ("Demarrage de Switch-Bridge.ps1 (InjectOnly) : AppPort={0} PanelPort={1} HttpPort={2} Notify={3}" -f $AppPort, $PanelPort, $HttpPort, ($(if ($NotifyUrl) { "$NotifyUrl -> $NotifyVariable" } else { 'off' })))
    try {
        & $bridge @bridgeArgs
    }
    catch {
        Log ("Switch-Bridge a leve une exception : {0}" -f $_.Exception.Message)
    }
    Log "Switch-Bridge s'est arrete. Relance dans 5 s."
    Start-Sleep -Seconds 5
}
