# UltimatteKey — Remote control for the Blackmagic Smart Remote 4

Trigger **Ultimatte unit switching** in the Blackmagic **Smart Remote** software over **HTTP**,
exactly as if someone had pressed a physical **UNIT** button on the panel — while the physical
panel keeps working normally.

A small man-in-the-middle (MITM) serial bridge sits between the panel and the software, captures
the panel's button protocol, and lets you **inject** the same commands through a tiny HTTP API.

---

## 1. What we learned about the panel and its protocol

### Transport
- The Smart Remote 4 panel does **not** use USB-HID. The buttons are **not** standard HID inputs
  (confirmed: capturing HID reports showed nothing).
- The panel talks to the software over a **serial port** (RS‑232 / USB-serial). On our machine the
  panel enumerated as **COM1** and the software opened that port.
- It is a **master/slave (polled)** protocol: the **software is the master** and polls continuously;
  the **panel is the slave** and only answers when something happens (e.g. a button press).

### Serial line parameters
Read from the OS (`mode COM1`, before renaming) — these are the exact settings the link uses:

```
Status for device COM1:
-----------------------
    Baud:            115200
    Parity:          Odd
    Data Bits:       8
    Stop Bits:       1
    Timeout:         OFF
    XON/XOFF:        ON
    CTS handshaking: OFF
    DSR handshaking: OFF
    DSR sensitivity: OFF
    DTR circuit:     ON
    RTS circuit:     ON
```

Summary: **115200 baud, Parity = Odd, 8 data bits, 1 stop bit, flow control = XON/XOFF, DTR = ON, RTS = ON.**

### Application protocol
- Plain **ASCII**, semicolon-terminated `KEY=VALUE;` tokens.
- The software continuously sends `Poll=0;` plus state/control tokens (LEDs, logo intensity, etc.),
  e.g. `Logo=0;`, `Logo=65535;`, `U1A=1;`, …
- The panel sends a button event as **`Switch=<mask>;`** when a UNIT button is pressed.

### UNIT button → `Switch=` mask (decoded)

| Button | Command       | Button | Command        |
|:------:|:--------------|:------:|:---------------|
| UNIT 1 | `Switch=4;`   | UNIT 5 | `Switch=8;`    |
| UNIT 2 | `Switch=32;`  | UNIT 6 | `Switch=64;`   |
| UNIT 3 | `Switch=256;` | UNIT 7 | `Switch=512;`  |
| UNIT 4 | `Switch=2048;`| UNIT 8 | `Switch=4096;` |

Injecting one of these values toward the software switches the corresponding Ultimatte unit.

---

## 2. Architecture (man-in-the-middle)

We free the real COM port from the software, put a virtual port in its place, and relay the traffic
through **hub4com** while a PowerShell script monitors the stream and injects commands on demand.

```
                          hub4com (relay + tee)
  [ Smart Remote SW ]            |
        opens COM1 (virtual)     |
            |                    |
  com0com:  COM1 <==> CNCB0 <-- port 1 --\
                                          >-- port 0 --> \\.\COM5  [ PHYSICAL PANEL ]
  com0com:  COM2 <==> CNCB1 <-- port 2 --/
            |
   [ Switch-Bridge.ps1 ]  reads COM2 (monitor) + writes COM2 (inject)
            |
        HTTP :8088  ->  GET /unit/3  =>  "Switch=256;"  =>  software switches UNIT 3
```

- **Port 0** = `\\.\COM5` — the real panel (renamed from COM1, see below).
- **Port 1** = `\\.\CNCB0` — partner of **COM1**, the virtual port the software opens.
- **Port 2** = `\\.\CNCB1` — partner of **COM2**, the port our bridge uses to monitor and inject.
- hub4com routes: `0:1,2` (panel → software + monitor), `1:0,2` (software → panel + monitor),
  and crucially `2:1` (**our injections on COM2 → software**).

---

## 3. Installation

### Prerequisites
- Windows with Windows PowerShell 5.1 (built in).
- [com0com](https://sourceforge.net/projects/com0com/) (signed build) — provides virtual COM port pairs.
- `hub4com.exe` (ships with the com0com "com2tcp/hub4com" tools) — multi-port serial hub.
- Administrator rights (for renaming ports, scheduled task, and firewall rule).

### Step 1 — Free COM1 and COM2 by renaming the physical ports
The software insists on opening **COM1**, and we also want **COM2** for the bridge. So move the
**physical** devices currently sitting on COM1 and COM2 out of the way:

- Open **Device Manager → Ports (COM & LPT)**.
- Physical **Smart Remote panel: COM1 → COM5** (Properties → Port Settings → Advanced → *COM Port Number*).
- The other physical port **COM2 → COM6**.

After this, **COM5 = the real panel** (used by hub4com), and **COM1 / COM2 are free** for com0com.

### Step 2 — Create the com0com virtual pairs
In the com0com setup console (`setupc.exe`), create two pairs whose first end is named COM1 / COM2
(the second end keeps the default `CNCB0` / `CNCB1`):

```
install PortName=COM1 -
install PortName=COM2 -
```

Result:
- Pair 0: **COM1** ⇄ **CNCB0**
- Pair 1: **COM2** ⇄ **CNCB1**

> The trailing `-` means "use defaults for the other end of the pair" (`CNCB0`, `CNCB1`).

### Step 3 — Start the hub4com relay
This relays the real panel (`COM5`) to the software (`CNCB0` ⇄ COM1) and tees everything to the
monitor port (`CNCB1` ⇄ COM2). The extra `--route=2:1` lets us inject back toward the software:

```bat
hub4com.exe --baud=115200 --parity=odd --octs=off ^
  --route=0:1,2 --route=1:0,2 --route=2:1 ^
  \\.\COM5 \\.\CNCB0 \\.\CNCB1
```

### Step 4 — Run our bridge (monitor + HTTP injection)
With the Smart Remote software running:

```powershell
.\Switch-Bridge.ps1 -InjectOnly -AppPort COM2 -HttpPort 8088
```

- Physical button presses appear in green (`BOUTON |Switch=256;|`), like a serial monitor.
- The HTTP server listens on the chosen port (default 8088).
- Add `-ShowAll` to see all traffic (including `Poll=0;`), `-LogFile <path>` to log to a file.

### Step 5 — Open the Windows Firewall (for access from other machines)
Without this, the API answers on `localhost` but **not** from other computers on the LAN.
The installer script (Step 6) does this automatically; to do it manually (admin):

```powershell
New-NetFirewallRule -DisplayName "UltimatteKeyBridge-HTTP" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8088 -Profile Any
```

### Step 6 — (Optional) Auto-start at boot, with no window
Run **once in an Administrator PowerShell**:

```powershell
.\Install-StartupTask.ps1 -HttpPort 8088
```

This registers a Scheduled Task that, at startup (after a short delay), launches **hub4com** hidden
then **Switch-Bridge** in inject mode — running as **SYSTEM**, "whether a user is logged on or not",
so **no window ever appears**. It also opens the firewall port.

- Change the port and apply immediately (no reboot): `.\Install-StartupTask.ps1 -HttpPort 9000 -Restart`
- Uninstall (task + firewall rule): `.\Install-StartupTask.ps1 -Remove`
- Progress/diagnostics are written to `bridge-boot.log` next to the scripts.

---

## 4. HTTP API

Base URL: `http://<host>:<port>/` (default port 8088).

| Method & path            | Effect                                                            |
|--------------------------|-------------------------------------------------------------------|
| `GET /`                  | Simple HTML page with clickable UNIT buttons.                     |
| `GET /health`            | `{"ok":true}` health check.                                       |
| `GET /unit/<1-8>`        | Press a UNIT button (maps to the proper `Switch=<mask>;`).        |
| `GET /switch/<value>`    | Send a raw `Switch=<value>;` command.                             |
| `GET /send?cmd=<text>`   | Send an arbitrary token (e.g. `?cmd=Switch=256;`).                |

Examples:

```powershell
Invoke-RestMethod http://localhost:8088/unit/3        # switch to UNIT 3
Invoke-RestMethod http://192.168.1.50:8088/unit/7     # from another machine on the LAN
Invoke-RestMethod "http://localhost:8088/send?cmd=Switch=256;"
```

---

## 5. Files in this repository

| File                       | Purpose                                                                       |
|----------------------------|-------------------------------------------------------------------------------|
| `Switch-Bridge.ps1`        | **Main script.** MITM monitor + HTTP injection API (`-InjectOnly` mode).      |
| `Start-Bridge-AtBoot.ps1`  | Boot launcher: starts hub4com hidden, then the bridge; logs to `bridge-boot.log`. |
| `Install-StartupTask.ps1`  | Registers/removes the hidden auto-start Scheduled Task and the firewall rule. |
| `Read-Serial.ps1`          | Full-duplex serial monitor used to reverse-engineer the protocol (diagnostic).|
| `Probe-Panel.ps1`          | Probes the physical panel / sweeps baud rates (diagnostic).                    |
| `Inspect-UsbHid.ps1`       | Confirms the buttons are not USB-HID (diagnostic).                             |
| `Switch-Ultimatte.ps1`     | Early keystroke/click attempt (superseded, kept for reference).               |
| `Bridge-Serial.ps1`        | Early pure-PowerShell relay attempt (superseded by hub4com + Switch-Bridge).  |

---

## 6. Troubleshooting

- **Works on localhost but not from the network** → open the firewall port (Step 5) **and** make
  sure the listener binds to all interfaces. Check the log line `HTTP en ecoute sur : http://+:<port>/`
  (good) vs `http://localhost:<port>/` (local only). Verify with
  `Get-NetTCPConnection -LocalPort <port> -State Listen` (LocalAddress `0.0.0.0` = all interfaces).
  From the client: `Test-NetConnection <host> -Port <port>`.
- **Changing the HTTP port "does nothing"** → a running instance keeps the old port. Re-run the
  installer with `-Restart`, or `Stop-ScheduledTask` then `Start-ScheduledTask`. Also kill any stale
  `Switch-Bridge.ps1` started manually that still holds the old port.
- **Software doesn't react to injection** → ensure hub4com includes `--route=2:1`, and that
  `-AppPort` is the com0com partner of the port the software opened (COM2 here).
- **No traffic at all** → confirm COM ports were renamed correctly (panel = COM5), the software is
  running, and the serial parameters match (115200/Odd/8/1, XON/XOFF).
- **`Read-Serial.ps1 -Port COM2`** is the reference tool to confirm you can see the panel↔software
  traffic while hub4com is running.
