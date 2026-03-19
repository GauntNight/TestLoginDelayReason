# Run as administrator for full data collection.
# When run as a standard user, AD-dependent and privileged sections are skipped gracefully.
<#
.SYNOPSIS
    AD Login Speed Diagnostic Script

.DESCRIPTION
    Measures and diagnoses slow login times on enterprise devices joined to
    an Active Directory domain. Identifies whether the root cause is:
      - Local device performance (CPU, RAM, disk)
      - Network connectivity / latency to domain controllers
      - GPO (Group Policy) processing time
      - Roaming profile loading
      - Logon scripts
      - DNS / DC discovery delays

.PARAMETER OutputPath
    Path to write the report file. Defaults to .\LoginSpeedReport.txt

.EXAMPLE
    .\LoginSpeedDiagnostic.ps1
    .\LoginSpeedDiagnostic.ps1 -OutputPath "C:\Temp\MyReport.txt"
#>

param(
    [string]$OutputPath = ".\LoginSpeedReport.txt"
)

# ─── Helpers ────────────────────────────────────────────────────────────────

$ReportLines = [System.Collections.Generic.List[string]]::new()
$DiagnosticSummary = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()
$ErrorLog = [System.Collections.Generic.List[PSCustomObject]]::new()

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

function Write-Section {
    param([string]$Title)
    $line = "`n" + ("=" * 70) + "`n  $Title`n" + ("=" * 70)
    $ReportLines.Add($line)
    Write-Host $line -ForegroundColor Cyan
}

function Write-Item {
    param([string]$Label, [string]$Value, [string]$Status = "INFO")
    $colors = @{ INFO = "White"; OK = "Green"; WARN = "Yellow"; FAIL = "Red" }
    $color  = if ($colors.ContainsKey($Status)) { $colors[$Status] } else { "White" }
    $text   = "  [{0,-4}] {1,-40} {2}" -f $Status, $Label, $Value
    $ReportLines.Add($text)
    Write-Host $text -ForegroundColor $color
    if ($Status -eq "WARN" -or $Status -eq "FAIL") {
        $Warnings.Add($text.Trim())
    }
}

function Write-Raw {
    param([string]$Text)
    $ReportLines.Add($Text)
    Write-Host $Text
}

function Write-ErrorLog {
    param(
        [ValidateSet("MissingCommand","MissingModule","SecurityFailure","OperationError")]
        [string]$Category,
        [string]$Source,
        [string]$Message
    )
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Category  = $Category
        Source    = $Source
        Message   = $Message
    }
    $ErrorLog.Add($entry)
    $status = if ($Category -eq "SecurityFailure") { "FAIL" } else { "WARN" }
    Write-Item -Label "$Source [$Category]" -Value $Message -Status $status
}

function Measure-MSec {
    param([scriptblock]$Block)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Block
    $sw.Stop()
    return [pscustomobject]@{ Result = $result; Ms = $sw.ElapsedMilliseconds }
}

function Get-StatusByMs {
    param([long]$Ms, [long]$OkMax, [long]$WarnMax)
    if ($Ms -le $OkMax)   { return "OK" }
    if ($Ms -le $WarnMax) { return "WARN" }
    return "FAIL"
}

# ─── Header ─────────────────────────────────────────────────────────────────

$RunTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$Header  = @"
╔══════════════════════════════════════════════════════════════════════╗
║           AD LOGIN SPEED DIAGNOSTIC REPORT                          ║
║  Generated : $RunTime                              ║
╚══════════════════════════════════════════════════════════════════════╝
"@
$ReportLines.Add($Header)
Write-Host $Header -ForegroundColor White

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1 – SYSTEM INFORMATION
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "1. SYSTEM INFORMATION"

$cs   = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS

Write-Item "Hostname"         $env:COMPUTERNAME
Write-Item "Domain"           $cs.Domain
$IsDomainJoined = $cs.PartOfDomain
Write-Item "Workgroup/Domain" $(if ($IsDomainJoined) { "Domain joined" } else { "NOT domain joined – AD sections will show N/A" }) `
           $(if ($IsDomainJoined) { "OK" } else { "WARN" })
Write-Item "Running as Admin"  $(if ($IsAdmin) { "Yes – full data collection" } else { "No – some sections require elevation" }) `
           $(if ($IsAdmin) { "OK" } else { "WARN" })

if (-not $IsDomainJoined) {
    $DiagnosticSummary.Add("Machine is not domain-joined. Sections 3-6 (AD/DC/GPO/Logon Events) are not applicable.")
}

Write-Item "OS"               "$($os.Caption) ($($os.Version))"
Write-Item "Architecture"     $env:PROCESSOR_ARCHITECTURE
Write-Item "Manufacturer"     $cs.Manufacturer
Write-Item "Model"            $cs.Model
Write-Item "BIOS Version"     $bios.SMBIOSBIOSVersion
Write-Item "Total RAM (GB)"   ([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
Write-Item "Logical CPUs"     $cs.NumberOfLogicalProcessors
Write-Item "Last Boot"        $os.LastBootUpTime
Write-Item "Uptime (hrs)"     ([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1))

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 – LOCAL DEVICE PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "2. LOCAL DEVICE PERFORMANCE"

# CPU load
$cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$cpuStatus = if ($cpuLoad -gt 80) { "WARN" } elseif ($cpuLoad -gt 90) { "FAIL" } else { "OK" }
Write-Item "Current CPU Load %" $cpuLoad $cpuStatus

# RAM available
$ramAvailGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$ramPctFree = [math]::Round(($os.FreePhysicalMemory / ($cs.TotalPhysicalMemory / 1KB)) * 100, 1)
$ramStatus  = if ($ramPctFree -lt 10) { "FAIL" } elseif ($ramPctFree -lt 20) { "WARN" } else { "OK" }
Write-Item "Free RAM (GB)"   $ramAvailGB $ramStatus
Write-Item "Free RAM %"      "$ramPctFree %" $ramStatus

# System drive
$sysDrive = Split-Path $env:SystemRoot -Qualifier
$disk     = Get-PSDrive -Name ($sysDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
if ($disk) {
    $diskFreeGB  = [math]::Round($disk.Free / 1GB, 1)
    $diskTotalGB = [math]::Round(($disk.Used + $disk.Free) / 1GB, 1)
    $diskPctFree = [math]::Round(($disk.Free / ($disk.Used + $disk.Free)) * 100, 1)
    $diskStatus  = if ($diskPctFree -lt 10) { "FAIL" } elseif ($diskPctFree -lt 20) { "WARN" } else { "OK" }
    Write-Item "System Drive Free (GB)" "$diskFreeGB / $diskTotalGB" $diskStatus
    Write-Item "System Drive Free %"    "$diskPctFree %" $diskStatus
}

# Disk type (SSD vs HDD) – approximate via MediaType if available
try {
    $diskMedia = Get-PhysicalDisk | Where-Object { $_.DeviceID -eq 0 } | Select-Object -ExpandProperty MediaType -ErrorAction Stop
    Write-Item "Primary Disk Type"  $diskMedia $(if ($diskMedia -eq "HDD") { "WARN" } else { "OK" })
} catch {
    Write-Item "Primary Disk Type"  "Unable to determine" "INFO"
}

# Pagefile usage
$pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
if ($pf) {
    $pfStatus = if ($pf.CurrentUsage -gt ($pf.AllocatedBaseSize * 0.8)) { "WARN" } else { "OK" }
    Write-Item "Pagefile Used (MB)"  "$($pf.CurrentUsage) / $($pf.AllocatedBaseSize)" $pfStatus
}

# Time since last boot (very fresh boot can be slow while services settle)
$uptimeHrs = ((Get-Date) - $os.LastBootUpTime).TotalHours
if ($uptimeHrs -lt 0.1) {
    Write-Item "Boot freshness"  "Device just booted – services still initialising" "WARN"
    $DiagnosticSummary.Add("Device booted very recently; background services may still be initialising.")
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3 – DNS AND DOMAIN CONTROLLER DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "3. DNS & DOMAIN CONTROLLER DISCOVERY"

if (-not $IsDomainJoined) {
    Write-Item "DNS & DC Discovery"  "N/A – machine is not domain-joined" "INFO"
} else {
    $domain = $cs.Domain

    # DNS resolution of the domain
    $dnsResult = Measure-MSec {
        try { [System.Net.Dns]::GetHostAddresses($domain) } catch { $null }
    }
    $dnsStatus = Get-StatusByMs -Ms $dnsResult.Ms -OkMax 200 -WarnMax 800
    Write-Item "DNS resolve domain (ms)"  $dnsResult.Ms $dnsStatus
    if (-not $dnsResult.Result) {
        Write-Item "DNS resolve result"  "FAILED – cannot resolve $domain" "FAIL"
        $DiagnosticSummary.Add("DNS resolution of the domain '$domain' failed. Check DNS server config.")
    } else {
        Write-Item "Domain resolves to"  ($dnsResult.Result | Select-Object -First 3 -ExpandProperty IPAddressToString) -join ", "
    }

    # nltest DC discovery
    $nltestResult = Measure-MSec {
        $out = & nltest.exe /dsgetdc:$domain 2>&1
        [pscustomobject]@{ Output = $out; Success = ($LASTEXITCODE -eq 0) }
    }
    $dcDiscStatus = if (-not $nltestResult.Result.Success) { "FAIL" }
                   elseif ($nltestResult.Ms -gt 3000)       { "FAIL" }
                   elseif ($nltestResult.Ms -gt 1000)       { "WARN" }
                   else                                      { "OK"   }
    Write-Item "DC discovery via nltest (ms)"  $nltestResult.Ms $dcDiscStatus

    if ($nltestResult.Result.Success) {
        $dcLine = $nltestResult.Result.Output | Where-Object { $_ -match "DC: \\\\" }
        if ($dcLine) {
            $dcName = ($dcLine -replace ".*DC: \\\\", "").Trim()
            Write-Item "Located Domain Controller"  $dcName
            $script:DC = $dcName
        }
        $siteLine = $nltestResult.Result.Output | Where-Object { $_ -match "Client Site Name" }
        if ($siteLine) {
            Write-Item "AD Site"  ($siteLine -replace ".*Client Site Name:\s*", "").Trim()
        }
    } else {
        Write-Item "DC discovery"  "FAILED – nltest returned errors" "FAIL"
        $DiagnosticSummary.Add("Domain controller discovery failed. Network or DNS issue likely.")
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4 – NETWORK CONNECTIVITY TO DOMAIN CONTROLLER
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "4. NETWORK CONNECTIVITY TO DOMAIN CONTROLLER"

if (-not $IsDomainJoined) {
    Write-Item "DC Network Connectivity"  "N/A – machine is not domain-joined" "INFO"
} else {
    if (-not $script:DC) {
        # Fallback: resolve DC from DNS SRV record
        try {
            $srvRecords = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -ErrorAction Stop
            $script:DC = ($srvRecords | Where-Object { $_.Type -eq "SRV" } | Select-Object -First 1).NameTarget.TrimEnd(".")
            Write-Item "Fallback DC (via SRV)"  $script:DC
        } catch {
            Write-Item "DC address"  "Could not determine DC address – skipping network tests" "WARN"
        }
    }

    if ($script:DC) {
        # Ping latency
        $ping = Test-Connection -ComputerName $script:DC -Count 4 -ErrorAction SilentlyContinue
        if ($ping) {
            $avgMs = [math]::Round(($ping | Measure-Object ResponseTime -Average).Average, 1)
            $pingStatus = if ($avgMs -gt 100) { "FAIL" } elseif ($avgMs -gt 40) { "WARN" } else { "OK" }
            Write-Item "Ping DC avg latency (ms)"  $avgMs $pingStatus
            if ($avgMs -gt 40) {
                $DiagnosticSummary.Add("High latency to DC ($avgMs ms). Consider whether DC is remote or network is congested.")
            }
        } else {
            Write-Item "Ping DC"  "No response (ICMP may be blocked)" "WARN"
        }

        # Key AD port tests
        $ports = @(
            @{ Port = 53;   Name = "DNS" }
            @{ Port = 88;   Name = "Kerberos" }
            @{ Port = 135;  Name = "RPC Endpoint Mapper" }
            @{ Port = 389;  Name = "LDAP" }
            @{ Port = 445;  Name = "SMB (SYSVOL/NETLOGON)" }
            @{ Port = 636;  Name = "LDAPS" }
            @{ Port = 3268; Name = "Global Catalog" }
        )

        foreach ($p in $ports) {
            $connResult = Measure-MSec {
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    $tcp.Connect($script:DC, $p.Port)
                    $tcp.Connected
                } catch { $false }
                finally { $tcp.Dispose() }
            }
            $open = $connResult.Result
            $portStatus = if ($open) { if ($connResult.Ms -gt 1000) { "WARN" } else { "OK" } } else { "FAIL" }
            Write-Item "Port $($p.Port) $($p.Name)"  $(if ($open) { "OPEN ($($connResult.Ms) ms)" } else { "CLOSED / FILTERED" }) $portStatus
            if (-not $open -and $p.Port -in @(88, 389, 445)) {
                $DiagnosticSummary.Add("Critical AD port $($p.Port) ($($p.Name)) is not reachable on DC $($script:DC).")
            }
        }

        # SMB / SYSVOL share availability
        $sysvolResult = Measure-MSec {
            Test-Path "\\$($script:DC)\SYSVOL" -ErrorAction SilentlyContinue
        }
        $sysvolStatus = if ($sysvolResult.Result) {
                            if ($sysvolResult.Ms -gt 3000) { "WARN" } else { "OK" }
                        } else { "FAIL" }
        Write-Item "SYSVOL share reachable"  $(if ($sysvolResult.Result) { "Yes ($($sysvolResult.Ms) ms)" } else { "No" }) $sysvolStatus
        if (-not $sysvolResult.Result) {
            $DiagnosticSummary.Add("SYSVOL is not reachable. GPOs and logon scripts cannot be applied from $($script:DC).")
        }
    }
}

# Network adapter info
Write-Raw "`n  Network Adapters:"
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    Write-Raw ("    {0,-30} {1,-15} Link: {2}" -f $_.Name, $_.InterfaceDescription, $_.LinkSpeed)
}

# Time sync (W32TM) – clock skew breaks Kerberos (> 5 min = auth failure)
Write-Raw ""
$w32tmOut = & w32tm.exe /query /status 2>&1
$stratumLine = $w32tmOut | Where-Object { $_ -match "Stratum" }
$skewLine    = $w32tmOut | Where-Object { $_ -match "Phase Offset|RootDelay" } | Select-Object -First 1
Write-Item "Time sync stratum"  ($stratumLine -replace ".*Stratum:\s*", "").Trim()
if ($skewLine) {
    Write-Item "Time offset/delay"  ($skewLine -replace ".*:\s*", "").Trim()
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 5 – GROUP POLICY PROCESSING TIMES (EVENT LOG)
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "5. GROUP POLICY PROCESSING TIMES (Last 5 logons)"

if (-not $IsDomainJoined) {
    Write-Item "Group Policy"  "N/A – machine is not domain-joined" "INFO"
} elseif (-not $IsAdmin) {
    Write-Item "Group Policy Event Log"  "Requires administrator rights to read – run as admin for GP timing data" "WARN"
}

try {
    $gpLog = Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" `
                           -MaxEvents 2000 -ErrorAction Stop

    # Event 8001 = GP processing start, Event 8002 = GP processing end
    $starts = $gpLog | Where-Object { $_.Id -eq 8001 } | Sort-Object TimeCreated -Descending
    $ends   = $gpLog | Where-Object { $_.Id -eq 8002 } | Sort-Object TimeCreated -Descending

    $matched = 0
    foreach ($start in $starts) {
        if ($matched -ge 5) { break }
        # Match by ActivityId
        $end = $ends | Where-Object { $_.ActivityId -eq $start.ActivityId } | Select-Object -First 1
        if ($end) {
            $durationMs = ($end.TimeCreated - $start.TimeCreated).TotalMilliseconds
            $gpStatus   = if ($durationMs -gt 120000) { "FAIL" } `
                          elseif ($durationMs -gt 60000) { "WARN" } `
                          else { "OK" }
            $isUser = $start.Message -match "user" -or $start.Properties[0].Value -match "user"
            $type   = if ($isUser) { "User GP " } else { "Computer GP" }
            Write-Item "$type session $(($matched+1)) – $($start.TimeCreated.ToString('MM-dd HH:mm'))" `
                       ("{0:N0} ms ({1:N1} sec)" -f $durationMs, ($durationMs / 1000)) $gpStatus
            if ($durationMs -gt 60000) {
                $DiagnosticSummary.Add("GP processing took $([math]::Round($durationMs/1000,1))s on $($start.TimeCreated.ToString('yyyy-MM-dd HH:mm')). Check slow CSEs or SYSVOL access.")
            }
            $matched++
        }
    }
    if ($matched -eq 0) {
        Write-Item "GP Events"  "No matched start/end pairs found in log" "WARN"
    }

    # Identify slow CSEs (Client-Side Extensions) – Event IDs 4016 / 5016
    Write-Raw "`n  Slow Group Policy CSEs (> 10 seconds):"
    $cseEvents = $gpLog | Where-Object { $_.Id -in @(5016, 4016) }
    $slowCses  = $cseEvents | Where-Object {
        ($_.Message -match "(\d+) milliseconds" -and [int]($Matches[1]) -gt 10000)
    }
    if ($slowCses.Count -gt 0) {
        $slowCses | Select-Object -First 10 | ForEach-Object {
            $ms  = if ($_.Message -match "(\d+) milliseconds") { $Matches[1] } else { "?" }
            $cse = if ($_.Message -match "CSE named (.+?) \(") { $Matches[1] } `
                   elseif ($_.Message -match "for (.+?) in") { $Matches[1] } `
                   else { "Unknown CSE" }
            Write-Item "  Slow CSE" "$cse – $ms ms" "WARN"
        }
    } else {
        Write-Item "  Slow CSEs" "None detected (all CSEs < 10 sec)" "OK"
    }
} catch {
    Write-Item "GP Event Log"  "Could not read Group Policy operational log: $_" "WARN"
}

# gpresult for applied GPOs count
Write-Raw ""
if (-not $IsDomainJoined) {
    Write-Item "Applied GPOs"  "N/A – machine is not domain-joined" "INFO"
} else {
    try {
        $gpresult = & gpresult.exe /R /SCOPE USER 2>&1
        $appliedLine = $gpresult | Where-Object { $_ -match "Applied Group Policy Objects" }
        $countLine   = $gpresult | Where-Object { $_ -match "The following GPOs were not applied" }
        $gpoLines    = $gpresult | Select-String "^\s{8}\S" | Select-Object -First 30
        Write-Item "Applied GPOs count"  $gpoLines.Count
        Write-Raw  "  Applied GPOs:"
        $gpoLines | ForEach-Object { Write-Raw "    - $($_.Line.Trim())" }
    } catch {
        Write-Item "GPResult"  "Could not run gpresult: $_" "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 6 – LOGON EVENT TIMING (Security Event Log)
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "6. RECENT INTERACTIVE LOGON EVENTS"

if (-not $IsAdmin) {
    Write-Item "Security Event Log"  "Requires administrator rights – run as admin to see logon events" "WARN"
} else {
    try {
        # Event 4624 Type 2 = Interactive logon, Type 10 = RemoteInteractive
        $logonEvents = Get-WinEvent -FilterHashtable @{
            LogName   = "Security"
            Id        = 4624
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 500 -ErrorAction Stop |
            Where-Object { $_.Message -match "Logon Type:\s+(2|10)\b" } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 10

        if ($logonEvents.Count -gt 0) {
            Write-Raw "  Last $($logonEvents.Count) interactive logon events:"
            $logonEvents | ForEach-Object {
                $userLine = $_.Message -split "`n" | Where-Object { $_ -match "Account Name:\s+\S" } | Select-Object -First 1
                $user     = if ($userLine -match "Account Name:\s+(.+)") { $Matches[1].Trim() } else { "Unknown" }
                $typeMatch = $_.Message -match "Logon Type:\s+(\d+)"
                $ltype    = if ($typeMatch) { if ($Matches[1] -eq "10") { "Remote" } else { "Local" } } else { "" }
                Write-Raw ("    {0}  User: {1,-30} {2}" -f $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss"), $user, $ltype)
            }
        } else {
            Write-Item "Logon Events"  "No interactive logons found in last 7 days" "WARN"
        }
    } catch {
        Write-Item "Security Log"  "Could not read Security event log: $_" "WARN"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 7 – USER PROFILE
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "7. USER PROFILE"

# Without admin, Win32_UserProfile only returns the current user's profile
$profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Special } |
            Sort-Object LastUseTime -Descending

if (-not $IsAdmin) {
    Write-Item "Profile enumeration"  "Running as standard user – showing current user profile only" "WARN"
}

Write-Raw "  Loaded profiles:"
$profiles | Select-Object -First 10 | ForEach-Object {
    $profilePath = $_.LocalPath
    $sizeGB      = "?"
    try {
        $sizeBytes = (Get-ChildItem $profilePath -Recurse -Force -ErrorAction SilentlyContinue |
                      Measure-Object Length -Sum).Sum
        $sizeGB    = [math]::Round($sizeBytes / 1GB, 2)
    } catch {}
    $isRoaming = $_.RoamingConfigured
    $status    = if ($isRoaming -and $sizeGB -is [double] -and $sizeGB -gt 2) { "WARN" } else { "OK" }
    Write-Item "  $($_.LocalPath)" "Size: $sizeGB GB  Roaming: $isRoaming  Last: $($_.LastUseTime.ToString('yyyy-MM-dd HH:mm'))" $status

    if ($isRoaming -and $sizeGB -is [double] -and $sizeGB -gt 2) {
        $DiagnosticSummary.Add("Roaming profile at '$profilePath' is $sizeGB GB – large roaming profiles greatly increase logon time.")
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 8 – LOGON SCRIPTS
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "8. LOGON SCRIPTS & STARTUP ITEMS"

# Check for logon scripts via Group Policy registry keys
$gpoLogonScripts = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Startup",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\User\Scripts\Logon"
)

$foundScripts = $false
foreach ($regPath in $gpoLogonScripts) {
    if (Test-Path $regPath) {
        $scripts = Get-ChildItem $regPath -ErrorAction SilentlyContinue
        foreach ($s in $scripts) {
            $scriptVal = Get-ItemProperty $s.PSPath -ErrorAction SilentlyContinue
            Write-Item "GP Script"  "$($scriptVal.Script) $($scriptVal.Parameters)" "INFO"
            $foundScripts = $true
        }
    }
}
if (-not $foundScripts) {
    Write-Item "GP Logon Scripts"  "None detected in registry" "OK"
}

# Startup programs (HKLM Run keys) – count only as proxy for load
$runKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($key in $runKeys) {
    try {
        $items = Get-ItemProperty $key -ErrorAction Stop
        $count = ($items.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" }).Count
        $kname = $key -replace ".*\\", ""
        $status = if ($count -gt 15) { "WARN" } else { "OK" }
        Write-Item "Startup entries ($kname)" $count $status
    } catch {}
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 9 – WINDOWS LOGON PERFORMANCE (Winlogon event channel)
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "9. WINDOWS LOGON PERFORMANCE EVENTS"

if (-not $IsAdmin) {
    Write-Item "Winlogon Event Log"  "Requires administrator rights – run as admin for Winlogon timing data" "WARN"
}

try {
    $winlogonEvents = Get-WinEvent -LogName "Microsoft-Windows-Winlogon/Operational" `
                                   -MaxEvents 200 -ErrorAction Stop |
                      Sort-Object TimeCreated -Descending

    $startEvents  = $winlogonEvents | Where-Object { $_.Id -eq 811 }  # Logon notification start
    $endEvents    = $winlogonEvents | Where-Object { $_.Id -eq 812 }  # Logon notification end

    if ($startEvents.Count -gt 0 -and $endEvents.Count -gt 0) {
        $count = 0
        foreach ($s in $startEvents) {
            if ($count -ge 5) { break }
            $e = $endEvents | Where-Object { $_.ActivityId -eq $s.ActivityId } | Select-Object -First 1
            if ($e) {
                $durationMs = ($e.TimeCreated - $s.TimeCreated).TotalMilliseconds
                $status     = if ($durationMs -gt 30000) { "FAIL" } elseif ($durationMs -gt 10000) { "WARN" } else { "OK" }
                Write-Item "Winlogon session $($count+1) – $($s.TimeCreated.ToString('MM-dd HH:mm'))" `
                           ("{0:N0} ms" -f $durationMs) $status
                $count++
            }
        }
    } else {
        Write-Item "Winlogon events"  "No start/end pairs found (events 811/812)" "INFO"
    }
} catch {
    Write-Item "Winlogon Log"  "Could not read Winlogon operational log: $_" "INFO"
}

# Credential providers / Winlogon notification packages
$notifPackages = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
                  -ErrorAction SilentlyContinue).WinlogonNotifyPackages
if ($notifPackages) {
    Write-Item "Winlogon Notify Packages"  $notifPackages "INFO"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 10 – NETLOGON LOG ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "10. NETLOGON LOG ANALYSIS"

if (-not $IsDomainJoined) {
    Write-Item "NETLOGON Log"  "N/A – machine is not domain-joined" "INFO"
}

$netlogonPath = "$env:SystemRoot\debug\netlogon.log"
if (Test-Path $netlogonPath) {
    $netlogon = Get-Content $netlogonPath -ErrorAction SilentlyContinue | Select-Object -Last 300
    $errors   = $netlogon | Where-Object { $_ -match "ERROR|CRITICAL|NO_RESPONSE" }
    $dcDisc   = $netlogon | Where-Object { $_ -match "DsGetDcName|Trying to find" }

    Write-Item "Netlogon log"   "Found at $netlogonPath"
    Write-Item "Last 300 lines" "Errors/warnings found: $($errors.Count)" `
               $(if ($errors.Count -gt 5) { "WARN" } elseif ($errors.Count -gt 0) { "WARN" } else { "OK" })

    if ($errors.Count -gt 0) {
        Write-Raw "  Recent NETLOGON errors:"
        $errors | Select-Object -Last 10 | ForEach-Object { Write-Raw "    $_" }
        $DiagnosticSummary.Add("NETLOGON.LOG contains $($errors.Count) errors – review $netlogonPath for authentication issues.")
    }
    if ($dcDisc.Count -gt 0) {
        Write-Raw "  DC discovery attempts (last 5):"
        $dcDisc | Select-Object -Last 5 | ForEach-Object { Write-Raw "    $_" }
    }
} else {
    Write-Item "Netlogon log"  "Not found at $netlogonPath (may need debug logging enabled)" "INFO"
    Write-Raw  "  To enable: nltest /dbflag:0x2080ffff"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 11 – DIAGNOSTIC SUMMARY & RECOMMENDATIONS
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "11. DIAGNOSTIC SUMMARY & RECOMMENDATIONS"

if ($Warnings.Count -gt 0) {
    Write-Raw "  Warnings / Failures detected:"
    $Warnings | ForEach-Object { Write-Raw "  $_" }
} else {
    Write-Raw "  No critical warnings detected."
}

Write-Raw ""
if ($DiagnosticSummary.Count -gt 0) {
    Write-Raw "  Root-cause pointers:"
    $i = 1
    $DiagnosticSummary | ForEach-Object {
        Write-Raw "  $i. $_"
        $i++
    }
} else {
    Write-Raw "  No specific root causes identified – login delay may be within normal range."
    Write-Raw "  Consider enabling boot/logon tracing: 'xbootmgr -trace logon -resultPath C:\traces'"
}

Write-Raw @"

  QUICK REFERENCE – Common root causes:
  ──────────────────────────────────────────────────────────────────────
  [Local device ]  High CPU/RAM/disk usage at logon; HDD vs SSD; many
                   startup programs; large local profile; AV scanning.
  [Network      ]  High DC ping latency (> 40ms); blocked AD ports (88,
                   389, 445); SYSVOL unreachable; wrong AD site assigned.
  [GPO          ]  Slow CSEs (Software Install, Folder Redirection, Scripts);
                   too many GPOs; WMI filters on slow hardware.
  [Profile      ]  Large roaming profile (> 1 GB); Folder Redirection to
                   slow share; corrupted NTUSER.DAT.
  [Logon scripts]  Long-running batch/VBS/PowerShell at logon.
  [Auth/Kerberos]  Clock skew > 5 min; missing SPN; NTLM fallback; DC
                   unavailable (Kerberos timeout ~30 sec).
  ──────────────────────────────────────────────────────────────────────
"@

# ─── Save Report ────────────────────────────────────────────────────────────

$ReportLines | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Host "`nReport written to: $OutputPath" -ForegroundColor Green
