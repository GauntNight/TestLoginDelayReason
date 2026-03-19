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

# ─── Encoding ────────────────────────────────────────────────────────────────
# External commands output in the system's OEM codepage (e.g., 932/Shift-JIS on
# Japanese Windows). Setting OutputEncoding to UTF-8 combined with chcp 65001
# ensures correct decoding. For commands that ignore chcp, we use structured
# alternatives (APIs, XML output) instead of text parsing.

$OriginalConsoleOutputEncoding = [Console]::OutputEncoding
$OriginalOutputEncoding        = $OutputEncoding

try { chcp 65001 | Out-Null } catch {}   # Ask console to use UTF-8 code page
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

$PSDefaultParameterValues['Out-File:Encoding']     = 'utf8'
$PSDefaultParameterValues['Set-Content:Encoding']   = 'utf8'
$PSDefaultParameterValues['Add-Content:Encoding']   = 'utf8'

# ─── Helpers ────────────────────────────────────────────────────────────────

$ReportLines = [System.Collections.Generic.List[string]]::new()
$DiagnosticSummary = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()
$ErrorLog = [System.Collections.Generic.List[PSCustomObject]]::new()
$SectionStatus = [ordered]@{}

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
    $text   = "  [$(Format-FixedWidth $Status 4)] $(Format-FixedWidth $Label 40) $Value"
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
        [ValidateSet("MissingCommand","MissingModule","MissingType","SecurityFailure","OperationError","EnvironmentIssue","TimeoutError")]
        [string]$Category,
        [string]$Source,
        [string]$Message,
        [string]$Remediation
    )
    $entry = [pscustomobject]@{
        Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Category    = $Category
        Source      = $Source
        Message     = $Message
        Remediation = $Remediation
    }
    $ErrorLog.Add($entry)
    $status = if ($Category -eq "SecurityFailure" -or $Category -eq "EnvironmentIssue") { "FAIL" } else { "WARN" }
    Write-Item -Label "$Source [$Category]" -Value $Message -Status $status
}

function Test-TypeAvailable {
    param([string]$TypeName)
    try { [type]$TypeName | Out-Null; return $true } catch { return $false }
}

function Test-ModuleAvailable {
    param([string]$ModuleName)
    return [bool](Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue)
}

function Measure-MSec {
    param([scriptblock]$Block)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $Block
    $sw.Stop()
    return [pscustomobject]@{ Result = $result; Ms = $sw.ElapsedMilliseconds }
}

function Invoke-WithTimeout {
    param(
        [scriptblock]$Block,
        [string]$Source = "Unknown",
        [int]$TimeoutSeconds = 30
    )
    $job = Start-Job -ScriptBlock $Block
    $completed = $job | Wait-Job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
        $job | Stop-Job
        $job | Remove-Job -Force
        Write-ErrorLog -Category "TimeoutError" -Source $Source `
            -Message "Operation timed out after ${TimeoutSeconds}s" `
            -Remediation "Check if $Source is responsive. Consider increasing the timeout or investigating connectivity issues."
        return $null
    }
    $result = $job | Receive-Job
    $job | Remove-Job -Force
    return $result
}

function Get-StatusByMs {
    param([long]$Ms, [long]$OkMax, [long]$WarnMax)
    if ($Ms -le $OkMax)   { return "OK" }
    if ($Ms -le $WarnMax) { return "WARN" }
    return "FAIL"
}

function Get-DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($char in $Text.ToCharArray()) {
        $cp = [int]$char
        # CJK Unified Ideographs, Katakana, Hiragana, Fullwidth forms, etc.
        if (($cp -ge 0x1100 -and $cp -le 0x115F) -or   # Hangul Jamo
            ($cp -ge 0x2E80 -and $cp -le 0x9FFF) -or   # CJK ranges
            ($cp -ge 0xAC00 -and $cp -le 0xD7AF) -or   # Hangul Syllables
            ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or   # CJK Compat Ideographs
            ($cp -ge 0xFE30 -and $cp -le 0xFE6F) -or   # CJK Compat Forms
            ($cp -ge 0xFF01 -and $cp -le 0xFF60) -or   # Fullwidth Forms
            ($cp -ge 0xFFE0 -and $cp -le 0xFFE6)) {    # Fullwidth Signs
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Format-FixedWidth {
    param([string]$Text, [int]$Width, [switch]$Right)
    $displayWidth = Get-DisplayWidth $Text
    $padding = [Math]::Max(0, $Width - $displayWidth)
    if ($Right) {
        return (' ' * $padding) + $Text
    } else {
        return $Text + (' ' * $padding)
    }
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

# ─── Pre-Flight Validation ──────────────────────────────────────────────────
Write-Section "PRE-FLIGHT VALIDATION"

# .NET Type availability checks
$RequiredTypes = @(
    @{ Name = "System.DirectoryServices.ActiveDirectory.DirectoryContext"; Purpose = "AD domain controller discovery" }
    @{ Name = "System.Net.Dns";                                           Purpose = "DNS resolution" }
    @{ Name = "System.Net.Sockets.TcpClient";                             Purpose = "TCP connectivity testing" }
    @{ Name = "System.Diagnostics.Stopwatch";                              Purpose = "Performance timing" }
)

$TypeAvailability = @{}
foreach ($t in $RequiredTypes) {
    $available = Test-TypeAvailable -TypeName $t.Name
    $TypeAvailability[$t.Name] = $available
    if ($available) {
        Write-Item -Label ".NET Type: $($t.Name.Split('.')[-1])" -Value "Available" -Status "OK"
    } else {
        Write-ErrorLog -Category "MissingType" -Source $t.Name `
            -Message "Type '$($t.Name)' not available – $($t.Purpose) will be skipped" `
            -Remediation "Ensure the required .NET assembly is loaded. For '$($t.Name)', verify that the .NET Framework or relevant assembly is installed."
    }
}

# PowerShell version check
$PSVer = $PSVersionTable.PSVersion
Write-Item -Label "PowerShell Version" -Value "$($PSVer.Major).$($PSVer.Minor).$($PSVer.Build)" -Status $(if ($PSVer -ge [version]"5.1") { "OK" } else { "WARN" })
if ($PSVer -lt [version]"5.1") {
    Write-ErrorLog -Category "EnvironmentIssue" -Source "PSVersion" `
        -Message "PowerShell $($PSVer) is below 5.1 – some cmdlets may be unavailable" `
        -Remediation "Upgrade to PowerShell 5.1 or later. Visit https://aka.ms/wmf5download or install PowerShell 7+ from https://aka.ms/powershell"
}

# Language mode detection
$LanguageMode = $ExecutionContext.SessionState.LanguageMode
$langStatus = if ($LanguageMode -eq "FullLanguage") { "OK" } else { "WARN" }
Write-Item -Label "Language Mode" -Value $LanguageMode -Status $langStatus
if ($LanguageMode -ne "FullLanguage") {
    Write-ErrorLog -Category "EnvironmentIssue" -Source "LanguageMode" `
        -Message "Running in $LanguageMode mode – some diagnostics may be restricted" `
        -Remediation "ConstrainedLanguage mode limits .NET type access. Run from a FullLanguage session or adjust Device Guard / AppLocker policies."
}

# Execution policy reporting
$ExecPolicy = Get-ExecutionPolicy
Write-Item -Label "Execution Policy" -Value $ExecPolicy -Status "INFO"

# PowerShell module availability checks
$RequiredModules = @(
    @{ Name = "ActiveDirectory";  Purpose = "AD user and group lookups" }
    @{ Name = "GroupPolicy";      Purpose = "GPO enumeration and analysis" }
    @{ Name = "DnsClient";        Purpose = "DNS diagnostics" }
    @{ Name = "NetAdapter";       Purpose = "Network adapter information" }
    @{ Name = "NetTCPIP";         Purpose = "TCP/IP configuration" }
    @{ Name = "BitsTransfer";     Purpose = "Background transfer diagnostics" }
    @{ Name = "ScheduledTasks";   Purpose = "Scheduled task analysis" }
)

$ModuleAvailability = @{}
foreach ($m in $RequiredModules) {
    $available = Test-ModuleAvailable -ModuleName $m.Name
    $ModuleAvailability[$m.Name] = $available
    if ($available) {
        Write-Item -Label "Module: $($m.Name)" -Value "Available" -Status "OK"
    } else {
        Write-ErrorLog -Category "MissingModule" -Source $m.Name `
            -Message "Module '$($m.Name)' not available – $($m.Purpose) may be limited" `
            -Remediation "Install the '$($m.Name)' module via 'Install-Module $($m.Name)' or enable the corresponding Windows feature (e.g., RSAT for ActiveDirectory/GroupPolicy)."
    }
}

Write-Item -Label "Pre-flight checks" -Value "Complete" -Status "INFO"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1 – SYSTEM INFORMATION
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "1. SYSTEM INFORMATION"
$SectionStatus["1. System Information"] = "In Progress"

try {
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
} catch {
    Write-ErrorLog -Category "OperationError" -Source "Section 1 - System Information" `
        -Message "Failed to retrieve system information via CIM: $($_.Exception.Message)" `
        -Remediation "Ensure the WMI/CIM service (winmgmt) is running. Try restarting it with: Restart-Service winmgmt -Force"
    # Fallback values so downstream sections can continue
    if (-not $cs)   { $cs   = [pscustomobject]@{ Domain = $env:USERDOMAIN; PartOfDomain = $false; Manufacturer = "Unknown"; Model = "Unknown"; TotalPhysicalMemory = 0; NumberOfLogicalProcessors = 0 } }
    if (-not $os)   { $os   = [pscustomobject]@{ Caption = "Unknown"; Version = "Unknown"; LastBootUpTime = Get-Date; FreePhysicalMemory = 0 } }
    if (-not $bios) { $bios = [pscustomobject]@{ SMBIOSBIOSVersion = "Unknown" } }
}

$IsDomainJoined = if ($cs.PSObject.Properties['PartOfDomain']) { $cs.PartOfDomain } else { $false }

Write-Item "Hostname"         $env:COMPUTERNAME
Write-Item "Domain"           $cs.Domain
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
Write-Item "Total RAM (GB)"   $(if ($cs.TotalPhysicalMemory -gt 0) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { "Unknown" })
Write-Item "Logical CPUs"     $(if ($cs.NumberOfLogicalProcessors -gt 0) { $cs.NumberOfLogicalProcessors } else { "Unknown" })
Write-Item "Last Boot"        $os.LastBootUpTime
Write-Item "Uptime (hrs)"     $(try { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } catch { "Unknown" })

$SectionStatus["1. System Information"] = if ($ErrorLog | Where-Object { $_.Source -like "*Section 1*" }) { "Partial" } else { "Completed" }

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 – LOCAL DEVICE PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════
Write-Section "2. LOCAL DEVICE PERFORMANCE"
$SectionStatus["2. Local Device Performance"] = "In Progress"
$section2Errors = 0

# CPU load
try {
    $cpuLoad = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
    $cpuStatus = if ($cpuLoad -gt 80) { "WARN" } elseif ($cpuLoad -gt 90) { "FAIL" } else { "OK" }
    Write-Item "Current CPU Load %" $cpuLoad $cpuStatus
} catch {
    $section2Errors++
    Write-ErrorLog -Category "OperationError" -Source "Section 2 - CPU Load" `
        -Message "Failed to retrieve CPU load via CIM: $($_.Exception.Message)" `
        -Remediation "Ensure the WMI/CIM service (winmgmt) is running and Win32_Processor class is accessible."
}

# RAM available
try {
    $ramAvailGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $ramPctFree = if ($cs.TotalPhysicalMemory -gt 0) {
        [math]::Round(($os.FreePhysicalMemory / ($cs.TotalPhysicalMemory / 1KB)) * 100, 1)
    } else { 0 }
    $ramStatus  = if ($ramPctFree -lt 10) { "FAIL" } elseif ($ramPctFree -lt 20) { "WARN" } else { "OK" }
    Write-Item "Free RAM (GB)"   $ramAvailGB $ramStatus
    Write-Item "Free RAM %"      "$ramPctFree %" $ramStatus
} catch {
    $section2Errors++
    Write-ErrorLog -Category "OperationError" -Source "Section 2 - RAM" `
        -Message "Failed to calculate RAM availability: $($_.Exception.Message)" `
        -Remediation "This may occur if System Information (Section 1) failed to retrieve OS/computer data."
}

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
try {
    $uptimeHrs = ((Get-Date) - $os.LastBootUpTime).TotalHours
    if ($uptimeHrs -lt 0.1) {
        Write-Item "Boot freshness"  "Device just booted – services still initialising" "WARN"
        $DiagnosticSummary.Add("Device booted very recently; background services may still be initialising.")
    }
} catch {
    # Non-critical; skip boot freshness check if LastBootUpTime is invalid
}

$SectionStatus["2. Local Device Performance"] = if ($section2Errors -gt 0) { "Partial" } else { "Completed" }

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

    # DC discovery via .NET API (locale-independent, no text parsing required)
    $dcDiscResult = Measure-MSec {
        try {
            $adContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new(
                [System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $domain
            )
            $dc = [System.DirectoryServices.ActiveDirectory.DomainController]::FindOne($adContext)
            [pscustomobject]@{ Name = $dc.Name; SiteName = $dc.SiteName; Success = $true; Method = ".NET API" }
        } catch {
            # Fallback: nltest with structural parsing (parse by DC:\\ pattern, locale-resilient)
            try {
                $out = & nltest.exe /dsgetdc:$domain 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $dcName = $null
                    $siteName = $null
                    foreach ($line in $out) {
                        if ($line -match '^\s*DC:\s*\\\\(.+)') {
                            $dcName = $Matches[1].Trim()
                        }
                        # Parse site by position: look for line with "DC Site Name" or site pattern
                        # The DC:\\ pattern is structural, not localized
                    }
                    [pscustomobject]@{ Name = $dcName; SiteName = $siteName; Success = ($null -ne $dcName); Method = "nltest fallback" }
                } else {
                    [pscustomobject]@{ Name = $null; SiteName = $null; Success = $false; Method = "nltest fallback" }
                }
            } catch {
                [pscustomobject]@{ Name = $null; SiteName = $null; Success = $false; Method = "failed" }
            }
        }
    }
    $dcDiscStatus = if (-not $dcDiscResult.Result.Success) { "FAIL" }
                   elseif ($dcDiscResult.Ms -gt 3000)       { "FAIL" }
                   elseif ($dcDiscResult.Ms -gt 1000)       { "WARN" }
                   else                                      { "OK"   }
    Write-Item "DC discovery (ms)"  "$($dcDiscResult.Ms) [$($dcDiscResult.Result.Method)]" $dcDiscStatus

    if ($dcDiscResult.Result.Success) {
        Write-Item "Located Domain Controller"  $dcDiscResult.Result.Name
        $script:DC = $dcDiscResult.Result.Name
        if ($dcDiscResult.Result.SiteName) {
            Write-Item "AD Site"  $dcDiscResult.Result.SiteName
        }
    } else {
        Write-Item "DC discovery"  "FAILED – could not locate domain controller" "FAIL"
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
    Write-Raw ("    $(Format-FixedWidth $_.Name 30) $(Format-FixedWidth $_.InterfaceDescription 15) Link: $($_.LinkSpeed)")
}

# Time sync (W32TM) – clock skew breaks Kerberos (> 5 min = auth failure)
Write-Raw ""
# Use w32tm /query /source (outputs only the source, no labels)
$timeSource = (& w32tm.exe /query /source 2>&1) | Select-Object -First 1
Write-Item "Time sync source" $timeSource.ToString().Trim()

# Use registry for NTP server config (locale-independent)
try {
    $ntpPeer = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -ErrorAction Stop
    Write-Item "NTP Server" $ntpPeer.NtpServer
} catch {
    Write-Item "Time config" "Could not query time configuration" "WARN"
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
            # Properties[0] = IsMachine (boolean/int): 1 = Computer, 0 = User
            $isMachine = [bool]([int]$start.Properties[0].Value)
            $isUser = -not $isMachine
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
    # Use structured XML access instead of Message parsing (locale-independent)
    Write-Raw "`n  Slow Group Policy CSEs (> 10 seconds):"
    $cseEvents = $gpLog | Where-Object { $_.Id -in @(5016, 4016) }
    $slowCses  = $cseEvents | Where-Object {
        $xml = [xml]$_.ToXml()
        $dataNodes = $xml.Event.EventData.Data
        $elapsed = ($dataNodes | Where-Object { $_.Name -eq 'CSEElaspedTimeInMilliSeconds' }).'#text'
        $elapsed -and [int]$elapsed -gt 10000
    }
    if ($slowCses.Count -gt 0) {
        $slowCses | Select-Object -First 10 | ForEach-Object {
            $xml = [xml]$_.ToXml()
            $dataNodes = $xml.Event.EventData.Data
            $ms  = ($dataNodes | Where-Object { $_.Name -eq 'CSEElaspedTimeInMilliSeconds' }).'#text'
            if (-not $ms) { $ms = "?" }
            $cse = ($dataNodes | Where-Object { $_.Name -eq 'CSEExtensionName' }).'#text'
            if (-not $cse) { $cse = "Unknown CSE" }
            Write-Item "  Slow CSE" "$cse – $ms ms" "WARN"
        }
    } else {
        Write-Item "  Slow CSEs" "None detected (all CSEs < 10 sec)" "OK"
    }
} catch {
    Write-Item "GP Event Log"  "Could not read Group Policy operational log: $_" "WARN"
}

# gpresult for applied GPOs count (using XML output for locale-independence)
Write-Raw ""
if (-not $IsDomainJoined) {
    Write-Item "Applied GPOs"  "N/A – machine is not domain-joined" "INFO"
} else {
    $gpXmlPath = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.xml'
    try {
        $null = & gpresult.exe /X $gpXmlPath /SCOPE USER /F 2>&1
        if (Test-Path $gpXmlPath) {
            [xml]$gpXml = Get-Content $gpXmlPath -Encoding UTF8
            # XML element names are NOT localized
            $appliedGPOs = $gpXml.Rsop.UserResults.GPO |
                Where-Object { $_.Link } |
                Select-Object -ExpandProperty Name
            if ($appliedGPOs) {
                Write-Item "Applied GPOs count"  $appliedGPOs.Count
                Write-Raw  "  Applied GPOs:"
                $appliedGPOs | ForEach-Object { Write-Raw "    - $_" }
            } else {
                Write-Item "Applied GPOs count"  "0"
            }
        } else {
            Write-Item "GPResult"  "gpresult /X did not produce output file" "WARN"
        }
    } catch {
        Write-Item "GPResult"  "Could not run gpresult: $_" "WARN"
    } finally {
        Remove-Item $gpXmlPath -Force -ErrorAction SilentlyContinue
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
        # Use structured XML access instead of Message text matching (locale-independent)
        $logonEvents = Get-WinEvent -FilterHashtable @{
            LogName   = "Security"
            Id        = 4624
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 500 -ErrorAction Stop |
            Where-Object {
                $xml = [xml]$_.ToXml()
                $dataNodes = $xml.Event.EventData.Data
                $logonType = ($dataNodes | Where-Object { $_.Name -eq 'LogonType' }).'#text'
                $logonType -eq '2' -or $logonType -eq '10'
            } |
            Sort-Object TimeCreated -Descending |
            Select-Object -First 10

        if ($logonEvents.Count -gt 0) {
            Write-Raw "  Last $($logonEvents.Count) interactive logon events:"
            $logonEvents | ForEach-Object {
                $xml = [xml]$_.ToXml()
                $dataNodes = $xml.Event.EventData.Data
                $user      = ($dataNodes | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
                if (-not $user) { $user = "Unknown" }
                $logonType = ($dataNodes | Where-Object { $_.Name -eq 'LogonType' }).'#text'
                $ltype     = if ($logonType -eq '10') { "Remote" } else { "Local" }
                Write-Raw ("    $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  User: $(Format-FixedWidth $user 30) $ltype")
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
    # Netlogon.log is written by the system in OEM codepage (e.g., CP932/Shift-JIS on Japanese Windows)
    $systemEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $netlogon = Get-Content $netlogonPath -Encoding $systemEncoding -ErrorAction SilentlyContinue | Select-Object -Last 300
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

# ─── Encoding Cleanup ───────────────────────────────────────────────────────
# Restore the user's original encoding settings so the script leaves no
# side effects on the PowerShell session.

[Console]::OutputEncoding = $OriginalConsoleOutputEncoding
$OutputEncoding           = $OriginalOutputEncoding
