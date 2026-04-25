# AD Login Speed Diagnostic Tool

A PowerShell-based diagnostic tool that identifies the root causes of slow Active Directory login times on Windows machines. It checks local device performance, network/DC connectivity, Group Policy processing, user profiles, logon scripts, and more — producing a detailed report with actionable recommendations.

## Prerequisites

- **Windows OS** (Windows 10/11 or Windows Server 2016+)
- **PowerShell 5.1** or later (included with Windows 10+)
- **Domain-joined machine** for full functionality (the tool runs in limited mode on non-domain machines)
- **Administrator elevation** (optional but recommended) — running as admin unlocks Security event log, GP timing, and Winlogon performance data

## Usage

### Method 1: Batch Launcher (Recommended)

Double-click `LoginSpeedDiagnostic.bat` or run it from a Command Prompt:

```cmd
LoginSpeedDiagnostic.bat
```

The `.bat` launcher automatically handles PowerShell execution policy (`-ExecutionPolicy Bypass`) and saves the report to a timestamped file (e.g., `LoginSpeedReport_2026-04-24_143022.txt`) in the same directory. A copy is also saved as `LoginSpeedReport_latest.txt` for easy access to the most recent report.

### Method 2: Run PowerShell Script Directly

```powershell
.\LoginSpeedDiagnostic.ps1
```

To save the report to a custom location:

```powershell
# Specify a directory - timestamped files will be created there
.\LoginSpeedDiagnostic.ps1 -OutputPath "C:\Temp"

# Specify a custom filename - timestamp will be inserted before extension
.\LoginSpeedDiagnostic.ps1 -OutputPath "C:\Temp\MyReport.txt"
# Creates: C:\Temp\MyReport_2026-04-24_143022.txt and MyReport_latest.txt
```

If execution policy blocks the script, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LoginSpeedDiagnostic.ps1
```

### Running as Administrator

For full diagnostic data, right-click the `.bat` file and select **Run as administrator**, or launch an elevated PowerShell/CMD window before running the script.

## Report Files and Versioning

The tool automatically versions report files with timestamps to preserve diagnostic history:

- **Timestamped reports**: Each run creates files with the format `LoginSpeedReport_YYYY-MM-DD_HHmmss.txt` (e.g., `LoginSpeedReport_2026-04-24_143022.txt`)
- **Latest copy**: A `LoginSpeedReport_latest.txt` file is always maintained, containing the most recent diagnostic results for quick access
- **No overwriting**: Previous reports are never overwritten, allowing you to compare results across multiple diagnostic runs
- **Output directory**: Use `-OutputPath` to specify where reports are saved:
  - **Directory path**: Reports are created in the specified directory with timestamped names
  - **File path**: The timestamp is inserted before the file extension, and a `_latest` copy is created alongside

**Example**: Running the diagnostic three times creates:
```
LoginSpeedReport_2026-04-24_140512.txt
LoginSpeedReport_2026-04-24_141823.txt
LoginSpeedReport_2026-04-24_143022.txt
LoginSpeedReport_latest.txt  (copy of the most recent report)
```

## What the Report Covers

The report contains 11 diagnostic sections:

| # | Section | What It Checks |
|---|---------|---------------|
| 1 | **System Information** | Hostname, domain membership, OS, hardware specs, uptime |
| 2 | **Local Device Performance** | CPU load, free RAM, disk space, disk type (SSD/HDD), pagefile usage |
| 3 | **DNS & DC Discovery** | DNS resolution of the domain, DC location via `nltest`, AD site assignment |
| 4 | **Network Connectivity to DC** | Ping latency, 7 critical AD port checks (DNS, Kerberos, LDAP, SMB, etc.), SYSVOL availability, time sync |
| 5 | **Group Policy Processing Times** | Last 5 GP processing durations, slow Client-Side Extensions (CSEs), applied GPO count |
| 6 | **Logon Event Timing** | Recent interactive logon events from the Security event log |
| 7 | **User Profile** | Profile sizes, roaming profile detection, large profile warnings |
| 8 | **Logon Scripts & Startup Items** | GP logon scripts, startup program counts from registry Run keys |
| 9 | **Winlogon Performance** | Winlogon notification timing (events 811/812), credential provider info |
| 10 | **NETLOGON Log Analysis** | Errors and DC discovery attempts from the NETLOGON debug log |
| 11 | **Diagnostic Summary** | Aggregated warnings, root-cause pointers, and a quick-reference guide |

## Warnings and Caveats

- **Non-admin runs are limited.** Without administrator elevation, the script skips the Security event log (section 6), GP timing data (section 5), and Winlogon performance events (section 9). The report will show `[WARN]` entries for these sections.

- **Non-domain machines get partial results.** Sections 3–6 (DNS/DC discovery, network connectivity, GPO processing, logon events) return N/A on machines not joined to an Active Directory domain. `nltest.exe` and `gpresult.exe` require domain membership.

- **Report files are automatically versioned.** Each run creates a timestamped report file (e.g., `LoginSpeedReport_2026-04-24_143022.txt`), preserving previous diagnostics for comparison. A `_latest` copy is always maintained for quick access to the most recent results.

- **NETLOGON log may not exist.** The debug log at `%SystemRoot%\debug\netlogon.log` is only present if NETLOGON debug logging has been enabled. To enable it:
  ```cmd
  nltest /dbflag:0x2080ffff
  ```

- **Profile size calculation scans recursively.** The script uses `Get-ChildItem -Recurse` on each user profile directory. On machines with very large profiles, this can be slow (see Performance section below).

## Performance Considerations

The script typically takes **1–5 minutes** to complete, depending on the environment. The following operations are the slowest:

| Operation | Why It's Slow | Impact |
|-----------|--------------|--------|
| **DC port scanning** | Tests 7 TCP ports (53, 88, 135, 389, 445, 636, 3268) with connection timeouts. Unreachable DCs cause each port to wait for the TCP timeout. | Can add 30+ seconds per unreachable port |
| **Profile size enumeration** | Recursively scans every file in each user profile directory. | On large profiles (100+ GB), this alone can take several minutes |
| **Event log queries** | Reads up to 2,000 Group Policy events and 500 Security events. | Noticeable on machines with large event logs |
| **`gpresult /R`** | Queries Active Directory for applied GPOs. | Can take 10–30 seconds, longer if DC is slow |
| **Ping tests** | Sends 4 ICMP packets to the domain controller. | ~4 seconds under normal conditions |

### Tips for Faster Runs

- If you only need a quick check and don't need profile sizes, be aware that profile enumeration cannot be skipped in the current version.
- On machines with unreachable DCs, expect longer runtimes due to TCP connection timeouts on each port.
- Running as a standard user skips several event log queries, which can actually make the script complete faster (though with less data).

## Understanding the Output

The report uses status indicators to highlight findings:

| Indicator | Meaning |
|-----------|---------|
| `[OK]` | Value is within normal/healthy range |
| `[WARN]` | Value is borderline or a potential concern |
| `[FAIL]` | Value is outside acceptable range — likely contributing to slow logins |
| `[INFO]` | Informational — no judgment on the value |

Section 11 (Diagnostic Summary) aggregates all warnings and failures, and provides root-cause pointers to help you prioritize investigation.

## Troubleshooting

**"Running scripts is disabled on this system"**
Use the `.bat` launcher, which passes `-ExecutionPolicy Bypass` automatically. Or run:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LoginSpeedDiagnostic.ps1
```

**"nltest is not recognized"**
`nltest.exe` is part of the Windows domain tools. It is available on domain-joined machines with RSAT installed. On non-domain machines, the script gracefully skips DC discovery.

**"Could not read Group Policy operational log"**
Run the script as administrator. The Group Policy event log requires elevated privileges.

**Sections show "N/A – machine is not domain-joined"**
The machine is not joined to an Active Directory domain. Sections 3–6 require domain membership. The tool still provides useful local performance data in sections 1, 2, 7, 8, and 9.

**Report file is empty or missing**
Ensure the output directory exists and is writable. Use the `-OutputPath` parameter to specify an alternative location.
