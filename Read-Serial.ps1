<#
.SYNOPSIS
    Moniteur serie FULL-DUPLEX : ENVOIE des commandes (TX, en cyan) ET affiche ce qui
    revient (RX, en vert), en HEXA + ASCII, sur le MEME port. Concu pour reverse-engineer
    le panneau de la Smart Remote 4 en lui parlant directement (role maitre).

    Zero-install : System.IO.Ports (inclus dans Windows PowerShell).

    Parametres physiques connus du panneau (via 'mode COM1') :
        -Baud 115200 -Parity Odd -DataBits 8 -StopBits One -Handshake XOnXOff

    IMPORTANT : port a acces EXCLUSIF. FERME le logiciel Smart Remote avant de lancer.

.PARAMETER Port       Nom du port (defaut COM1).
.PARAMETER Baud       Vitesse en bauds (defaut 115200).
.PARAMETER Parity     None/Odd/Even/Mark/Space (defaut Odd).
.PARAMETER DataBits   Bits de donnees (defaut 8).
.PARAMETER StopBits   None/One/Two/OnePointFive (defaut One).
.PARAMETER Handshake  None/XOnXOff/RequestToSend/RequestToSendXOnXOff (defaut XOnXOff).
.PARAMETER Seconds    Duree (defaut 60).
.PARAMETER Send       Chaine ASCII a ENVOYER (TX). Ex : 'Poll=0;' ou 'Logo=0;'.
.PARAMETER Send2      2e chaine ; avec -SendMs, ALTERNE Send <-> Send2 (ex : faire clignoter).
.PARAMETER SendMs     0 = envoie -Send UNE fois a l'ouverture ; >0 = repete tous les SendMs ms.
.PARAMETER ScanBaud   Teste plusieurs bauds (8 s chacun).
.PARAMETER DtrOff     Desactive DTR (par defaut DTR active).
.PARAMETER RtsOff     Desactive RTS (par defaut RTS active).
.PARAMETER Match      N'affiche QUE les RX dont l'ASCII correspond a ce regex.
.PARAMETER Hide       Masque les RX dont l'ASCII correspond a ce regex (ex : '^(?:Poll=0;)+$').
.PARAMETER List       Liste les ports serie disponibles.

.EXAMPLE
    # Interroger le panneau et VOIR envois + reponses (appuyer sur les boutons) :
    .\Read-Serial.ps1 -Port COM1 -Send 'Poll=0;' -SendMs 100 -Seconds 60

.EXAMPLE
    # Diagnostiquer le "seule la 1re valeur passe" : faire clignoter le logo, voir les TX :
    .\Read-Serial.ps1 -Port COM1 -Send 'Logo=0;' -Send2 'Logo=65535;' -SendMs 500 -Seconds 20

.EXAMPLE
    # Si les TX echouent (XON/XOFF bloque) : reessayer SANS controle de flux :
    .\Read-Serial.ps1 -Port COM1 -Handshake None -Send 'Logo=0;' -Send2 'Logo=65535;' -SendMs 500
#>
[CmdletBinding()]
param(
    [string]$Port = 'COM5',
    [int]$Baud = 115200,
    [ValidateSet('None', 'Odd', 'Even', 'Mark', 'Space')][string]$Parity = 'Odd',
    [int]$DataBits = 8,
    [ValidateSet('None', 'One', 'Two', 'OnePointFive')][string]$StopBits = 'One',
    [ValidateSet('None', 'XOnXOff', 'RequestToSend', 'RequestToSendXOnXOff')][string]$Handshake = 'XOnXOff',
    [int]$Seconds = 60,
    [string]$Send,
    [string]$Send2,
    [int]$SendMs = 0,
    [switch]$ScanBaud,
    [switch]$DtrOff,
    [switch]$RtsOff,
    [string]$Match,
    [string]$Hide,
    [switch]$List
)

if ($List) {
    Write-Host "Ports serie disponibles :" -ForegroundColor Cyan
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object | ForEach-Object { Write-Host "  $_" }
    return
}

function Format-Frame([byte[]]$bytes, [int]$count) {
    $hex = ''; $asc = ''
    for ($i = 0; $i -lt $count; $i++) {
        $b = $bytes[$i]
        $hex += ('{0:X2} ' -f $b)
        $asc += if ($b -ge 32 -and $b -le 126) { [char]$b } else { '.' }
    }
    return [pscustomobject]@{ Hex = $hex.TrimEnd(); Ascii = $asc; Count = $count }
}

function Invoke-Listen {
    param(
        [string]$Port, [int]$Baud, [string]$Parity, [int]$DataBits, [string]$StopBits, [string]$Handshake,
        [int]$Seconds, [bool]$Dtr, [bool]$Rts,
        [string]$Send, [string]$Send2, [int]$SendMs, [switch]$Summary
    )
    $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]$Parity), $DataBits, ([System.IO.Ports.StopBits]$StopBits)
    $sp.ReadTimeout = 200
    $sp.WriteTimeout = 300
    $sp.Handshake = [System.IO.Ports.Handshake]$Handshake
    $sp.DtrEnable = $Dtr
    $sp.RtsEnable = $Rts
    try { $sp.Open() }
    catch {
        Write-Error "Ouverture de $Port impossible : $($_.Exception.Message)"
        Write-Host "  -> Si 'acces refuse' : FERME le logiciel Smart Remote, puis relance." -ForegroundColor Yellow
        return $null
    }

    $sendBytes = if ($Send) { [System.Text.Encoding]::ASCII.GetBytes($Send) } else { $null }
    $send2Bytes = if ($Send2) { [System.Text.Encoding]::ASCII.GetBytes($Send2) } else { $null }
    $useSecond = $false; $sentOnce = $false; $nextSend = [DateTime]::MinValue
    $total = 0; $sample = $null; $prev = $null; $txFail = 0
    try {
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            # ---- TX (envoi) ----
            if ($sendBytes) {
                $due = $false
                if ($SendMs -gt 0) {
                    if ((Get-Date) -ge $nextSend) { $due = $true; $nextSend = (Get-Date).AddMilliseconds($SendMs) }
                }
                elseif (-not $sentOnce) { $due = $true }
                if ($due) {
                    $payload = if ($send2Bytes -and $useSecond) { $send2Bytes } else { $sendBytes }
                    $txt = [System.Text.Encoding]::ASCII.GetString($payload)
                    $ok = $true
                    try { $sp.Write($payload, 0, $payload.Length) } catch { $ok = $false; $txFail++ }
                    $useSecond = -not $useSecond; $sentOnce = $true
                    if (-not $Summary) {
                        $ts = (Get-Date).ToString('HH:mm:ss.fff')
                        if ($ok) {
                            Write-Host ("{0}  TX ->            |{1}|" -f $ts, $txt) -ForegroundColor Cyan
                        }
                        else {
                            Write-Host ("{0}  TX ->  ECHEC     |{1}|  (write bloque : XON/XOFF ? -> essaie -Handshake None)" -f $ts, $txt) -ForegroundColor Red
                        }
                    }
                }
            }
            # ---- RX (reception) ----
            if ($sp.BytesToRead -gt 0) {
                Start-Sleep -Milliseconds 25
                $n = $sp.BytesToRead
                $buf = New-Object byte[] $n
                $read = $sp.Read($buf, 0, $n)
                $total += $read
                $f = Format-Frame $buf $read
                if (-not $sample) { $sample = $f.Ascii }
                $show = $true
                if ($Match -and $f.Ascii -notmatch $Match) { $show = $false }
                if ($Hide -and $f.Ascii -match $Hide) { $show = $false }
                if (-not $Summary -and $show) {
                    $ts = (Get-Date).ToString('HH:mm:ss.fff')
                    $note = if ($prev -eq $f.Hex) { '  (idem)' } else { '' }
                    Write-Host ("{0}  RX <-  [{1,3}o]  {2}   |{3}|{4}" -f $ts, $f.Count, $f.Hex, $f.Ascii, $note) -ForegroundColor Green
                }
                $prev = $f.Hex
            }
            else { Start-Sleep -Milliseconds 5 }
        }
    }
    finally {
        if ($sp.IsOpen) { $sp.Close() }
        $sp.Dispose()
    }
    return [pscustomobject]@{ Baud = $Baud; Total = $total; Sample = $sample; TxFail = $txFail }
}

$dtr = -not $DtrOff
$rts = -not $RtsOff
Write-Host ("Port {0}  |  Trame {1}/{2}/{3}  Flux={4}  |  DTR={5} RTS={6}" -f $Port, $DataBits, $Parity, $StopBits, $Handshake, $dtr, $rts) -ForegroundColor DarkGray
if ($Send) {
    $alt = if ($Send2) { " <-> '$Send2'" } else { '' }
    $rep = if ($SendMs -gt 0) { "toutes les $SendMs ms" } else { 'une seule fois' }
    Write-Host ("Envoi (TX) : '{0}'{1}  {2}" -f $Send, $alt, $rep) -ForegroundColor DarkGray
}

if ($ScanBaud) {
    Write-Host "`nSCAN de baud sur $Port. APPUIE SUR LES BOUTONS SANS ARRET pendant tout le scan...`n" -ForegroundColor Green
    $bauds = 9600, 19200, 38400, 57600, 115200, 230400
    $results = @()
    foreach ($b in $bauds) {
        Write-Host ("--- Test {0} bauds (8 s) ---" -f $b) -ForegroundColor Cyan
        $r = Invoke-Listen -Port $Port -Baud $b -Parity $Parity -DataBits $DataBits -StopBits $StopBits -Handshake $Handshake -Seconds 8 -Dtr $dtr -Rts $rts -Send $Send -Send2 $Send2 -SendMs $SendMs -Summary
        if ($null -eq $r) { return }
        Write-Host ("    -> {0} octets recus    echantillon: {1}" -f $r.Total, ($(if ($r.Sample) { $r.Sample } else { '(rien)' })))
        $results += $r
    }
    Write-Host "`n=== Resume ===" -ForegroundColor Cyan
    $results | Format-Table Baud, Total, Sample -AutoSize
    return
}

Write-Host "`n$Port : TX en cyan, RX en vert. Ctrl+C pour arreter.`n" -ForegroundColor Green
$r = Invoke-Listen -Port $Port -Baud $Baud -Parity $Parity -DataBits $DataBits -StopBits $StopBits -Handshake $Handshake -Seconds $Seconds -Dtr $dtr -Rts $rts -Send $Send -Send2 $Send2 -SendMs $SendMs
if ($null -ne $r) {
    Write-Host ("`nTotal recu (RX) : {0} octets." -f $r.Total) -ForegroundColor Green
    if ($r.TxFail -gt 0) {
        Write-Host ("{0} envois (TX) ont ECHOUE : le panneau bloque probablement via XON/XOFF." -f $r.TxFail) -ForegroundColor Yellow
        Write-Host "  -> Reessaie avec -Handshake None pour ignorer le controle de flux." -ForegroundColor Yellow
    }
}
