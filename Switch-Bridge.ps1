<#
.SYNOPSIS
    Pont "homme du milieu" (MITM) entre le PANNEAU physique de la Smart Remote 4 et le
    LOGICIEL Smart Remote, AVEC un serveur HTTP qui permet d'INJECTER des appuis de
    boutons UNITS a distance.

    - Sens PANNEAU -> APPLI : les appuis physiques (Switch=N;) continuent de marcher.
    - Sens APPLI  -> PANNEAU : l'appli pilote toujours le panneau (LED, logo, etc.).
    - Injection HTTP : une requete GET /unit/3 ecrit "Switch=256;" vers l'appli,
      exactement comme si on avait appuye sur UNIT 3 sur le panneau.

    Carte des boutons (decodee) :
        UNIT 1 = Switch=4;     UNIT 5 = Switch=8;
        UNIT 2 = Switch=32;    UNIT 6 = Switch=64;
        UNIT 3 = Switch=256;   UNIT 7 = Switch=512;
        UNIT 4 = Switch=2048;  UNIT 8 = Switch=4096;

    Zero-install : System.IO.Ports + System.Net.HttpListener (inclus dans Windows).

    TOPOLOGIE (com0com requis) :
        [ Logiciel ] --ouvre--> COM1 (virtuel) <=paire com0com=> COM2 <--ouvre-- [ CE PONT ] --ouvre--> COM5 (panneau physique)
      => Le logiciel ouvre COM1 (virtuel). Le panneau physique a ete renomme COM5.
         -AppPort = COM2 (le bout com0com partenaire de COM1).  -PanelPort = COM5.

.PARAMETER AppPort     Port com0com que CE PONT ouvre cote logiciel (partenaire du COM1 du logiciel). Defaut COM2.
.PARAMETER PanelPort   Port PHYSIQUE du panneau (renomme). Defaut COM5.
.PARAMETER Baud        Defaut 115200.
.PARAMETER Parity      Defaut Odd.
.PARAMETER DataBits    Defaut 8.
.PARAMETER StopBits    Defaut One.
.PARAMETER Handshake   Defaut XOnXOff (controle de flux logiciel, comme le vrai lien).
.PARAMETER DtrOff      Desactive DTR cote panneau (par defaut ON).
.PARAMETER RtsOff      Desactive RTS cote panneau (par defaut ON).
.PARAMETER HttpPort    Port d'ecoute du serveur HTTP. Defaut 8088.
.PARAMETER HttpPrefix  (Avance) Prefixe d'ecoute HTTP complet, ex 'http://+:9000/'. S'il est
                       fourni, il a la priorite sur -HttpPort. Sinon deduit de -HttpPort.
                       Si acces refuse (pas admin), bascule auto sur localhost.
.PARAMETER NotifyUrl   URL de base a notifier quand l'utilisateur change d'unite MANUELLEMENT
                       (appui physique). Ex Companion : 'http://127.0.0.1:8000'. Requiert aussi
                       -NotifyVariable. Le pont envoie alors un POST a :
                         <NotifyUrl>/api/custom-variable/<NotifyVariable>/value
                       avec le NUMERO d'unite (1-8) dans le corps de la requete.
.PARAMETER NotifyVariable  Nom de la variable personnalisee Companion a mettre a jour.
.PARAMETER WithRelease Apres chaque injection, envoie aussi 'Switch=0;' (relachement).
.PARAMETER ShowAll     Affiche TOUT le trafic (sinon : seulement boutons + injections).
.PARAMETER InjectOnly  N'ouvre PAS le panneau : se contente d'ecrire les injections vers
                       -AppPort. A utiliser quand hub4com fait deja le relais panneau<->logiciel
                       et reinjecte -AppPort vers le logiciel (ex. route 2:1).
.PARAMETER List        Liste les ports serie.

.EXAMPLE
    .\Switch-Bridge.ps1 -AppPort COM2 -PanelPort COM5
    # Puis depuis un navigateur : http://<ip-de-la-SR4>:8088/  (ou /unit/3)

.EXAMPLE
    # Injection en ligne de commande :
    Invoke-RestMethod http://localhost:8088/unit/3

.EXAMPLE
    # Mode INJECTION SEULE : hub4com fait le relais panneau<->logiciel ET duplique le trafic
    # vers COM2 (port moniteur). On REPREND TA commande qui marche, en AJOUTANT --route=2:1
    # pour que ce qu'on ECRIT sur COM2 reparte vers le logiciel (CNCB0) :
    #
    #   hub4com.exe --baud=9600 --octs=off --route=0:1,2 --route=1:0,2 --route=2:1 \
    #               \\.\COM5 \\.\CNCB0 \\.\CNCB1
    #
    # Puis (logiciel lance) :
    .\Switch-Bridge.ps1 -InjectOnly -AppPort COM2
    #   -> affiche les appuis (BOUTON, vert) comme Read-Serial, et /unit/3 injecte vers le logiciel.

.EXAMPLE
    # En plus : prevenir Companion (variable perso 'ultimatte_unit') des changements MANUELS :
    .\Switch-Bridge.ps1 -InjectOnly -AppPort COM2 -NotifyUrl 'http://127.0.0.1:8000' -NotifyVariable 'ultimatte_unit'
    #   -> appui physique UNIT 3 => POST http://127.0.0.1:8000/api/custom-variable/ultimatte_unit/value  (corps : 3)
#>
[CmdletBinding()]
param(
    [string]$AppPort = 'COM2',
    [string]$PanelPort = 'COM5',
    [int]$Baud = 115200,
    [ValidateSet('None', 'Odd', 'Even', 'Mark', 'Space')][string]$Parity = 'Odd',
    [int]$DataBits = 8,
    [ValidateSet('None', 'One', 'Two', 'OnePointFive')][string]$StopBits = 'One',
    [ValidateSet('None', 'XOnXOff', 'RequestToSend', 'RequestToSendXOnXOff')][string]$Handshake = 'XOnXOff',
    [switch]$DtrOff,
    [switch]$RtsOff,
    [int]$HttpPort = 8088,
    [string]$HttpPrefix,
    [string]$NotifyUrl,
    [string]$NotifyVariable,
    [string]$LogFile,
    [switch]$WithRelease,
    [switch]$ShowAll,
    [switch]$InjectOnly,
    [switch]$List
)

# Le prefixe HTTP se deduit de -HttpPort, sauf si -HttpPrefix est fourni explicitement (cas avance).
if (-not $HttpPrefix) { $HttpPrefix = "http://+:$HttpPort/" }

# Journalisation optionnelle (utile quand lance sans fenetre par une tache planifiee).
function Write-Log([string]$msg) {
    if (-not $LogFile) { return }
    try { Add-Content -Path $LogFile -Value ("{0}  [bridge] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch {}
}
Write-Log ("Demarrage : AppPort={0} PanelPort={1} HttpPrefix={2} InjectOnly={3}" -f $AppPort, $PanelPort, $HttpPrefix, [bool]$InjectOnly)

# Carte boutons UNITS -> masque Switch (decode depuis les logs du panneau).
# NB : table de hachage NORMALE (pas [ordered]) -> $map[$n] indexe par CLE, pas par position.
$UnitMap = @{
    1 = 4; 2 = 32; 3 = 256; 4 = 2048; 5 = 8; 6 = 64; 7 = 512; 8 = 4096
}

# Carte inverse masque -> numero d'unite (pour detecter les appuis PHYSIQUES dans le flux).
$MaskToUnit = @{}
foreach ($k in $UnitMap.Keys) { $MaskToUnit[[int]$UnitMap[$k]] = [int]$k }

# Notification sortante (POST vers Companion) sur changement d'unite MANUEL (appui physique).
$NotifyEnabled = [bool]($NotifyUrl -and $NotifyVariable)
$notifyQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:lastInjectAt = [DateTime]::MinValue

# Extrait le 1er numero d'unite reconnu d'une trame ASCII contenant 'Switch=<masque>;'.
function Get-UnitFromAscii([string]$asc) {
    foreach ($mm in [regex]::Matches($asc, 'Switch=(\d+);')) {
        $val = [int]$mm.Groups[1].Value
        if ($MaskToUnit.Contains($val)) { return $MaskToUnit[$val] }
    }
    return $null
}

# Met en file une notification si la trame est un appui physique reconnu (et pas l'echo d'une injection).
function Send-ButtonNotify([string]$asc) {
    if (-not $NotifyEnabled) { return }
    $u = Get-UnitFromAscii $asc
    if ($null -eq $u) { return }
    if (((Get-Date) - $script:lastInjectAt).TotalMilliseconds -lt 400) { return }  # anti-boucle / anti-echo
    $notifyQueue.Enqueue([int]$u)
    Write-Log ("NOTIFY file d'attente : unit={0}" -f $u)
}

if ($List) {
    Write-Host "Ports serie disponibles :" -ForegroundColor Cyan
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
    return
}

function New-Port {
    param([string]$Name, [int]$Baud, [string]$Parity, [int]$DataBits, [string]$StopBits, [string]$Handshake, [bool]$Dtr, [bool]$Rts)
    $sp = New-Object System.IO.Ports.SerialPort $Name, $Baud, ([System.IO.Ports.Parity]$Parity), $DataBits, ([System.IO.Ports.StopBits]$StopBits)
    $sp.ReadTimeout = 50
    $sp.WriteTimeout = 300
    $sp.Handshake = [System.IO.Ports.Handshake]$Handshake
    $sp.DtrEnable = $Dtr
    $sp.RtsEnable = $Rts
    return $sp
}

function Format-Ascii([byte[]]$Buf, [int]$Count) {
    $asc = ''
    for ($i = 0; $i -lt $Count; $i++) { $b = $Buf[$i]; $asc += if ($b -ge 32 -and $b -le 126) { [char]$b } else { '.' } }
    return $asc
}

# Ouverture robuste : essaie le nom tel quel, puis le prefixe espace-noyau '\\.\NOM'.
function Open-Serial {
    param([string]$Name, [int]$Baud, [string]$Parity, [int]$DataBits, [string]$StopBits, [string]$Handshake, [bool]$Dtr, [bool]$Rts)
    $names = @($Name)
    if ($Name -notmatch '^\\\\\.\\') { $names += ('\\.\' + $Name) }
    $err = $null
    foreach ($nm in $names) {
        $sp = $null
        try {
            $sp = New-Port -Name $nm -Baud $Baud -Parity $Parity -DataBits $DataBits -StopBits $StopBits -Handshake $Handshake -Dtr $Dtr -Rts $Rts
            $sp.Open()
            return $sp
        } catch { $err = $_; if ($sp) { try { $sp.Dispose() } catch {} } }
    }
    throw $err
}

# ---------------------------------------------------------------------------
# Ouverture des ports serie
# ---------------------------------------------------------------------------
$dtr = -not $DtrOff
$rts = -not $RtsOff

$seen = ([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique) -join ', '

try { $app = Open-Serial -Name $AppPort -Baud $Baud -Parity $Parity -DataBits $DataBits -StopBits $StopBits -Handshake 'None' -Dtr $true -Rts $true }
catch {
    Write-Error "Ouverture de $AppPort (cote logiciel) impossible : $($_.Exception.Message)"
    Write-Host "  Ports vus par .NET : $seen" -ForegroundColor Yellow
    Write-Host "  -> -AppPort doit etre le partenaire com0com du port ouvert par le logiciel (ex : COM2)." -ForegroundColor Yellow
    return
}
# En mode -InjectOnly : hub4com fait le relais panneau<->logiciel. Ce script ne fait
# qu'INJECTER (ecrire vers AppPort, que hub4com reinjecte vers le logiciel). Pas de panneau ici.
$panel = $null
if (-not $InjectOnly) {
    try { $panel = Open-Serial -Name $PanelPort -Baud $Baud -Parity $Parity -DataBits $DataBits -StopBits $StopBits -Handshake $Handshake -Dtr $dtr -Rts $rts }
    catch {
        Write-Error "Ouverture de $PanelPort (panneau physique) impossible : $($_.Exception.Message)"
        Write-Host "  Ports vus par .NET : $seen" -ForegroundColor Yellow
        Write-Host "  Pistes :" -ForegroundColor Yellow
        Write-Host "   - $PanelPort est-il dans la liste ci-dessus ? Si NON : le renommage n'est pas pris -> dans" -ForegroundColor Yellow
        Write-Host "     le Gestionnaire de peripheriques, DESACTIVE puis REACTIVE le port (ou debranche/rebranche, ou reboot)." -ForegroundColor Yellow
        Write-Host "   - Un autre programme le tient-il ? Ferme hub4com, le logiciel, tout autre script serie." -ForegroundColor Yellow
        Write-Host "   - Essaie aussi -PanelPort '\\.\$PanelPort'." -ForegroundColor Yellow
        if ($app.IsOpen) { $app.Close() }; $app.Dispose()
        return
    }
}

# ---------------------------------------------------------------------------
# Serveur HTTP (dans un runspace separe) : depose des commandes dans une file.
# ---------------------------------------------------------------------------
$injectQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$state = [hashtable]::Synchronized(@{ Running = $true; Listener = $null; UsedPrefix = $null; LastError = $null })

$httpScript = {
    param($prefix, $queue, $state, $unitMap)

    $prefixes = @($prefix)
    if ($prefix -match '^http://(\+|\*):(\d+)/') { $prefixes += "http://localhost:$($matches[2])/" }

    $listener = $null
    foreach ($p in $prefixes) {
        try {
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add($p)
            $l.Start()
            $listener = $l; $state.Listener = $l; $state.UsedPrefix = $p
            break
        } catch { $state.LastError = $_.Exception.Message }
    }
    if (-not $listener) { $state.Running = $false; return }

    function Send-Reply($ctx, [int]$code, [string]$body, [string]$type = 'application/json') {
        try {
            $ctx.Response.StatusCode = $code
            $ctx.Response.ContentType = $type
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {} finally { try { $ctx.Response.Close() } catch {} }
    }

    while ($state.Running) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $path = $ctx.Request.Url.AbsolutePath.Trim('/')
            $segs = if ($path) { $path.Split('/') } else { @() }
            $from = $ctx.Request.RemoteEndPoint.Address.ToString()

            if ($segs.Count -eq 0) {
                $links = ($unitMap.Keys | Sort-Object | ForEach-Object { "<a href='/unit/$_'>UNIT $_</a>" }) -join ' &nbsp; '
                $html = "<html><head><meta charset='utf-8'><title>Switch Bridge</title></head><body style='font-family:sans-serif'>" +
                        "<h2>Smart Remote - Switch Bridge</h2><p>Cliquez pour basculer :</p><p style='font-size:1.3em'>$links</p>" +
                        "<p>API : <code>GET /unit/&lt;1-8&gt;</code>, <code>GET /switch/&lt;valeur&gt;</code>, <code>GET /send?cmd=...</code></p></body></html>"
                Send-Reply $ctx 200 $html 'text/html; charset=utf-8'
            }
            elseif ($segs[0] -eq 'health') {
                Send-Reply $ctx 200 '{"ok":true}'
            }
            elseif ($segs[0] -eq 'unit' -and $segs.Count -ge 2) {
                $n = 0
                if ([int]::TryParse($segs[1], [ref]$n) -and $unitMap.Contains($n)) {
                    $val = $unitMap[$n]; $cmd = "Switch=$val;"
                    $queue.Enqueue(@{ Cmd = $cmd; Label = "UNIT $n (de $from)" })
                    Send-Reply $ctx 200 ("{{`"ok`":true,`"unit`":{0},`"sent`":`"{1}`"}}" -f $n, $cmd)
                } else {
                    Send-Reply $ctx 400 '{"ok":false,"error":"unit must be 1..8"}'
                }
            }
            elseif ($segs[0] -eq 'switch' -and $segs.Count -ge 2) {
                $v = 0
                if ([int]::TryParse($segs[1], [ref]$v)) {
                    $cmd = "Switch=$v;"
                    $queue.Enqueue(@{ Cmd = $cmd; Label = "switch=$v (de $from)" })
                    Send-Reply $ctx 200 ("{{`"ok`":true,`"sent`":`"{0}`"}}" -f $cmd)
                } else {
                    Send-Reply $ctx 400 '{"ok":false,"error":"value must be integer"}'
                }
            }
            elseif ($segs[0] -eq 'send') {
                $cmd = $ctx.Request.QueryString['cmd']
                if ($cmd) {
                    $queue.Enqueue(@{ Cmd = $cmd; Label = "brut (de $from)" })
                    Send-Reply $ctx 200 ("{{`"ok`":true,`"sent`":`"{0}`"}}" -f $cmd)
                } else {
                    Send-Reply $ctx 400 '{"ok":false,"error":"missing ?cmd="}'
                }
            }
            else {
                Send-Reply $ctx 404 '{"ok":false,"error":"not found"}'
            }
        } catch {}
    }
    try { $listener.Stop(); $listener.Close() } catch {}
}

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
$null = $ps.AddScript($httpScript.ToString()).AddArgument($HttpPrefix).AddArgument($injectQueue).AddArgument($state).AddArgument($UnitMap)
$httpHandle = $ps.BeginInvoke()

# --- Runspace de NOTIFICATION sortante (POST Companion) : envoi non bloquant via une file ---
$notifyState = [hashtable]::Synchronized(@{ Running = $true })
$notifyPs = $null; $notifyHandle = $null; $notifyRs = $null
if ($NotifyEnabled) {
    $notifyScript = {
        param($baseUrl, $varName, $queue, $state, $logFile)
        function NLog([string]$m) {
            if ($logFile) { try { Add-Content -Path $logFile -Value ("{0}  [notify] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
        }
        $uri = ("{0}/api/custom-variable/{1}/value" -f $baseUrl.TrimEnd('/'), $varName)
        while ($state.Running) {
            if ($queue.Count -gt 0) {
                $val = $queue.Dequeue()
                try {
                    Invoke-RestMethod -Method Post -Uri $uri -Body ([string]$val) -ContentType 'text/plain' -TimeoutSec 5 | Out-Null
                    NLog ("POST {0} corps={1} OK" -f $uri, $val)
                } catch {
                    NLog ("POST {0} corps={1} ECHEC : {2}" -f $uri, $val, $_.Exception.Message)
                }
            } else {
                Start-Sleep -Milliseconds 20
            }
        }
    }
    $notifyRs = [runspacefactory]::CreateRunspace(); $notifyRs.Open()
    $notifyPs = [powershell]::Create(); $notifyPs.Runspace = $notifyRs
    $null = $notifyPs.AddScript($notifyScript.ToString()).AddArgument($NotifyUrl).AddArgument($NotifyVariable).AddArgument($notifyQueue).AddArgument($notifyState).AddArgument($LogFile)
    $notifyHandle = $notifyPs.BeginInvoke()
}

# Attendre que le serveur HTTP demarre (max ~3 s)
$deadline = (Get-Date).AddSeconds(3)
while (-not $state.UsedPrefix -and -not $state.LastError -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }

if ($InjectOnly) {
    Write-Host ("Mode INJECTION SEULE : moniteur+injection sur {0} (hub4com relaie panneau<->logiciel)." -f $AppPort) -ForegroundColor Cyan
    Write-Host "  Pre-requis hub4com : ajouter --route=2:1 pour que l'injection reparte vers le logiciel." -ForegroundColor DarkYellow
} else {
    Write-Host ("Pont actif : LOGICIEL[{0}] <-> PANNEAU[{1}]  ({2} {3}/{4}/{5}, flux {6})" -f $AppPort, $PanelPort, $Baud, $DataBits, $Parity, $StopBits, $Handshake) -ForegroundColor Cyan
}
if ($state.UsedPrefix) {
    Write-Host ("HTTP en ecoute sur : {0}" -f $state.UsedPrefix) -ForegroundColor Green
    Write-Log ("HTTP en ecoute sur : {0}" -f $state.UsedPrefix)
    if ($state.UsedPrefix -match 'localhost') {
        Write-Host ("  (acces local seulement. Pour le reseau : lance en ADMIN, ou : netsh http add urlacl url=http://+:{0}/ user=Everyone)" -f $HttpPort) -ForegroundColor DarkYellow
    }
    Write-Host "  Exemples : /unit/3   /switch/256   /send?cmd=Switch=256;" -ForegroundColor DarkGray
} else {
    Write-Host ("ATTENTION : serveur HTTP non demarre. {0}" -f $state.LastError) -ForegroundColor Red
    Write-Log ("ERREUR : serveur HTTP non demarre. {0}" -f $state.LastError)
}
if ($NotifyEnabled) {
    $notifyUri = ("{0}/api/custom-variable/{1}/value" -f $NotifyUrl.TrimEnd('/'), $NotifyVariable)
    Write-Host ("Notification appui MANUEL -> POST {0} (corps = numero d'unite)." -f $notifyUri) -ForegroundColor Cyan
    Write-Log ("Notification activee : POST {0}" -f $notifyUri)
}
Write-Host "Boutons physiques (vert) et injections (magenta) ci-dessous. Ctrl+C pour arreter.`n" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Boucle de pont : transmet app<->panneau, et injecte les commandes HTTP vers l'appli.
# ---------------------------------------------------------------------------
try {
    while ($true) {
        $did = $false

        # Injections HTTP -> ecrites vers l'APPLI (comme si le panneau les envoyait)
        while ($injectQueue.Count -gt 0) {
            $item = $injectQueue.Dequeue()
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($item.Cmd)
            try {
                $app.Write($bytes, 0, $bytes.Length)
                if ($WithRelease) { $rel = [System.Text.Encoding]::ASCII.GetBytes('Switch=0;'); $app.Write($rel, 0, $rel.Length) }
                $script:lastInjectAt = Get-Date   # anti-boucle : ne pas notifier l'echo de notre propre injection
                Write-Host ("{0}  INJECT >>  {1}  |{2}|{3}" -f (Get-Date).ToString('HH:mm:ss.fff'), $item.Label, $item.Cmd, ($(if ($WithRelease) { 'Switch=0;' } else { '' }))) -ForegroundColor Magenta
                Write-Log ("INJECT {0} -> {1}" -f $item.Label, $item.Cmd)
            } catch {
                Write-Host ("{0}  INJECT ECHEC : {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $_.Exception.Message) -ForegroundColor Red
                Write-Log ("INJECT ECHEC : {0}" -f $_.Exception.Message)
            }
            $did = $true
        }

        # Lecture du port -AppPort.
        #  - Pont complet  : flux APPLI -> on le relaie vers le PANNEAU physique.
        #  - -InjectOnly   : COM2 est le port MONITEUR de hub4com (les 2 sens y sont dupliques).
        #                    On AFFICHE comme Read-Serial et on detecte les appuis 'Switch='.
        if ($app.BytesToRead -gt 0) {
            if ($InjectOnly) { Start-Sleep -Milliseconds 25 }  # laisse une trame complete arriver (comme Read-Serial)
            $n = $app.BytesToRead; $buf = New-Object byte[] $n; $r = $app.Read($buf, 0, $n)
            if ((-not $InjectOnly) -and $panel) { try { $panel.Write($buf, 0, $r) } catch {} }
            $asc = Format-Ascii $buf $r
            if ($InjectOnly) {
                if ($asc -match 'Switch=') { Write-Host ("{0}  BOUTON    |{1}|" -f (Get-Date).ToString('HH:mm:ss.fff'), $asc) -ForegroundColor Green; Send-ButtonNotify $asc }
                elseif ($ShowAll) { Write-Host ("{0}  MONITEUR  |{1}|" -f (Get-Date).ToString('HH:mm:ss.fff'), $asc) -ForegroundColor DarkGray }
            }
            elseif ($ShowAll) { Write-Host ("{0}  PC->PAN   |{1}|" -f (Get-Date).ToString('HH:mm:ss.fff'), $asc) -ForegroundColor DarkGray }
            $did = $true
        }

        # PANNEAU -> APPLI  (uniquement en mode pont complet)
        if ((-not $InjectOnly) -and $panel -and $panel.BytesToRead -gt 0) {
            $n = $panel.BytesToRead; $buf = New-Object byte[] $n; $r = $panel.Read($buf, 0, $n)
            try { $app.Write($buf, 0, $r) } catch {}
            $asc = Format-Ascii $buf $r
            if ($ShowAll) { Write-Host ("{0}  PAN->PC   |{1}|" -f (Get-Date).ToString('HH:mm:ss.fff'), $asc) -ForegroundColor Green }
            elseif ($asc -match 'Switch=') { Write-Host ("{0}  BOUTON    |{1}|" -f (Get-Date).ToString('HH:mm:ss.fff'), $asc) -ForegroundColor Green }
            if ($asc -match 'Switch=') { Send-ButtonNotify $asc }
            $did = $true
        }

        if (-not $did) { Start-Sleep -Milliseconds 2 }
    }
}
finally {
    $state.Running = $false
    $notifyState.Running = $false
    try { if ($state.Listener) { $state.Listener.Stop(); $state.Listener.Close() } } catch {}
    try { $ps.Stop() } catch {}
    try { $ps.EndInvoke($httpHandle) } catch {}
    try { $rs.Close() } catch {}
    if ($notifyPs) { try { $notifyPs.Stop() } catch {}; try { $notifyPs.EndInvoke($notifyHandle) } catch {}; try { $notifyRs.Close() } catch {} }
    if ($panel) { if ($panel.IsOpen) { $panel.Close() }; $panel.Dispose() }
    if ($app.IsOpen) { $app.Close() }; $app.Dispose()
    Write-Host "`nArrete." -ForegroundColor Cyan
}
