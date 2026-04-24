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
    Path to write the report file. Defaults to .\LoginSpeedReport_YYYYMMDD_HHmmss.txt

.PARAMETER Quick
    Run in quick mode, skipping time-intensive checks

.PARAMETER Sections
    Specific sections to run. If omitted, all sections are run.

.PARAMETER NoHtml
    Suppress HTML report generation. By default, both text and HTML reports are created.

.EXAMPLE
    .\LoginSpeedDiagnostic.ps1
    .\LoginSpeedDiagnostic.ps1 -OutputPath "C:\Temp\MyReport.txt"
    .\LoginSpeedDiagnostic.ps1 -Quick
    .\LoginSpeedDiagnostic.ps1 -Sections 1,3,5
    .\LoginSpeedDiagnostic.ps1 -Quick -Sections 4,7
    .\LoginSpeedDiagnostic.ps1 -NoHtml
#>

param(
    [string]$OutputPath,
    [switch]$Quick,
    [int[]]$Sections,
    [switch]$NoHtml
)

# ─── Generate Timestamped Output Path ───────────────────────────────────────
if ([string]::IsNullOrEmpty($OutputPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = ".\LoginSpeedReport_$timestamp.txt"
}

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

function Test-ShouldRunSection {
    param([int]$SectionNumber)
    if ($null -eq $Sections -or $Sections.Count -eq 0) {
        return $true
    }
    return $Sections -contains $SectionNumber
}

# ─── HTML Generation Helpers ────────────────────────────────────────────────

function ConvertTo-HtmlEscaped {
    param([string]$Text)
    if (-not $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;").Replace("'", "&#39;")
}

function Get-StatusClass {
    param([string]$Status)
    switch ($Status) {
        "OK"   { return "status-ok" }
        "WARN" { return "status-warn" }
        "FAIL" { return "status-fail" }
        default { return "status-info" }
    }
}

function Get-SectionSeverity {
    param(
        [string]$SectionTitle,
        [System.Collections.Generic.List[string]]$ReportLines,
        [hashtable]$SectionStatus
    )

    # Check if section status explicitly indicates completion state
    $status = $SectionStatus[$SectionTitle]
    if ($status -eq "Skipped") { return "info" }
    if ($status -eq "In Progress") { return "warn" }

    # Count FAIL and WARN items in this section
    $inSection = $false
    $failCount = 0
    $warnCount = 0

    foreach ($line in $ReportLines) {
        # Detect section start
        if ($line -match "^={70}$") {
            $inSection = $false
        }
        if ($line -match "^\s+(.+)$" -and $ReportLines[$ReportLines.IndexOf($line) - 1] -match "^={70}$") {
            if ($Matches[1].Trim() -eq $SectionTitle) {
                $inSection = $true
            }
            continue
        }

        # Count status in section
        if ($inSection -and $line -match '^\s+\[(FAIL|WARN|OK)\]') {
            $itemStatus = $Matches[1]
            if ($itemStatus -eq "FAIL") { $failCount++ }
            if ($itemStatus -eq "WARN") { $warnCount++ }
        }
    }

    # Determine severity based on counts
    if ($failCount -gt 0) { return "fail" }
    if ($warnCount -gt 0) { return "warn" }
    return "ok"
}

function Get-HtmlTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="description" content="Windows Login Speed Diagnostic Report">
  <title>Login Speed Diagnostic Report</title>
  <style>
    :root {
      --color-ok: #10b981;
      --color-warn: #f59e0b;
      --color-fail: #ef4444;
      --color-info: #3b82f6;
      --color-ok-bg: #d1fae5;
      --color-warn-bg: #fef3c7;
      --color-fail-bg: #fee2e2;
      --color-info-bg: #eff6ff;
      --color-primary: #0078d4;
      --color-primary-hover: #005a9e;
      --color-bg: #f8fafc;
      --color-surface: #ffffff;
      --color-border: #e2e8f0;
      --color-text: #1e293b;
      --color-text-secondary: #64748b;
      --color-text-muted: #94a3b8;
      --font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
      --font-mono: 'Cascadia Code', 'Fira Code', 'Consolas', monospace;
    }
    *, *::before, *::after {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    body {
      font-family: var(--font-family);
      font-size: 16px;
      color: var(--color-text);
      background-color: var(--color-bg);
      line-height: 1.6;
      min-height: 100vh;
    }
    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 2rem;
    }
    .header {
      background-color: var(--color-surface);
      border-bottom: 1px solid var(--color-border);
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
      padding: 1.5rem 2rem;
      margin-bottom: 2rem;
    }
    .header h1 {
      font-size: 1.875rem;
      font-weight: 700;
      color: var(--color-primary);
    }
    .header .subtitle {
      font-size: 0.875rem;
      color: var(--color-text-secondary);
      margin-top: 0.25rem;
    }
    .section {
      background-color: var(--color-surface);
      border: 1px solid var(--color-border);
      border-radius: 0.5rem;
      margin-bottom: 1.5rem;
      overflow: hidden;
    }
    .section.severity-ok {
      border-left: 4px solid var(--color-ok);
    }
    .section.severity-warn {
      border-left: 4px solid var(--color-warn);
    }
    .section.severity-fail {
      border-left: 4px solid var(--color-fail);
    }
    .section.severity-info {
      border-left: 4px solid var(--color-info);
    }
    .section-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1.5rem;
      cursor: pointer;
      user-select: none;
      transition: background-color 0.2s ease;
    }
    .section-header:hover {
      background-color: var(--color-bg);
    }
    .section-title {
      font-size: 1.25rem;
      font-weight: 600;
      color: var(--color-text);
      margin: 0;
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }
    .severity-badge {
      display: inline-flex;
      align-items: center;
      padding: 0.25rem 0.75rem;
      border-radius: 0.25rem;
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
    }
    .severity-badge.ok {
      background-color: var(--color-ok-bg);
      color: var(--color-ok);
    }
    .severity-badge.warn {
      background-color: var(--color-warn-bg);
      color: var(--color-warn);
    }
    .severity-badge.fail {
      background-color: var(--color-fail-bg);
      color: var(--color-fail);
    }
    .severity-badge.info {
      background-color: var(--color-info-bg);
      color: var(--color-info);
    }
    .toggle-icon {
      width: 24px;
      height: 24px;
      transition: transform 0.2s ease;
      flex-shrink: 0;
    }
    .section.collapsed .toggle-icon {
      transform: rotate(-90deg);
    }
    .section-content {
      padding: 0 1.5rem 1.5rem 1.5rem;
      max-height: 10000px;
      overflow: hidden;
      transition: max-height 0.3s ease, padding 0.3s ease;
    }
    .section.collapsed .section-content {
      max-height: 0;
      padding-top: 0;
      padding-bottom: 0;
    }
    .item {
      display: grid;
      grid-template-columns: 40% 1fr auto;
      gap: 1rem;
      padding: 0.5rem 0;
      border-bottom: 1px solid var(--color-border);
    }
    .item:last-child {
      border-bottom: none;
    }
    .item-label {
      font-weight: 500;
      color: var(--color-text);
    }
    .item-value {
      color: var(--color-text-secondary);
      word-break: break-word;
    }
    .item-status {
      padding: 0.25rem 0.75rem;
      border-radius: 0.25rem;
      font-size: 0.75rem;
      font-weight: 600;
      text-align: center;
      min-width: 60px;
    }
    .status-ok {
      background-color: var(--color-ok-bg);
      color: var(--color-ok);
    }
    .status-warn {
      background-color: var(--color-warn-bg);
      color: var(--color-warn);
    }
    .status-fail {
      background-color: var(--color-fail-bg);
      color: var(--color-fail);
    }
    .status-info {
      background-color: var(--color-info-bg);
      color: var(--color-info);
    }
    .summary-box {
      background-color: var(--color-warn-bg);
      border-left: 4px solid var(--color-warn);
      padding: 1rem;
      margin-bottom: 1rem;
      border-radius: 0.25rem;
    }
    .summary-box ul {
      margin-left: 1.5rem;
      margin-top: 0.5rem;
    }
    .error-log {
      background-color: var(--color-fail-bg);
      border-left: 4px solid var(--color-fail);
      padding: 1rem;
      margin-top: 1rem;
      border-radius: 0.25rem;
      font-family: var(--font-mono);
      font-size: 0.875rem;
    }
    .footer {
      text-align: center;
      padding: 2rem;
      color: var(--color-text-muted);
      font-size: 0.875rem;
    }
    pre {
      font-family: var(--font-mono);
      background-color: var(--color-bg);
      padding: 0.75rem;
      border-radius: 0.25rem;
      overflow-x: auto;
      margin-top: 0.5rem;
    }
    .expand-collapse-all {
      display: flex;
      gap: 1rem;
      margin-bottom: 1.5rem;
      justify-content: flex-end;
    }
    .btn {
      padding: 0.5rem 1rem;
      border: 1px solid var(--color-border);
      border-radius: 0.375rem;
      background-color: var(--color-surface);
      color: var(--color-text);
      font-size: 0.875rem;
      font-weight: 500;
      cursor: pointer;
      transition: all 0.2s ease;
    }
    .btn:hover {
      background-color: var(--color-primary);
      border-color: var(--color-primary);
      color: white;
    }
    .btn:active {
      transform: translateY(1px);
    }
    .executive-summary {
      background: linear-gradient(135deg, var(--color-surface) 0%, #f0f4f8 100%);
      border: 2px solid var(--color-border);
      border-radius: 0.75rem;
      padding: 2rem;
      margin-bottom: 2rem;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.07);
    }
    .executive-summary h2 {
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--color-text);
      margin-bottom: 1.5rem;
      padding-bottom: 0.75rem;
      border-bottom: 3px solid var(--color-primary);
    }
    .summary-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
      gap: 1.5rem;
      margin-bottom: 1.5rem;
    }
    .summary-card {
      background-color: var(--color-surface);
      border: 1px solid var(--color-border);
      border-radius: 0.5rem;
      padding: 1.25rem;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05);
    }
    .summary-card h3 {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--color-text-secondary);
      margin-bottom: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .health-score {
      font-size: 3rem;
      font-weight: 700;
      line-height: 1;
      margin-bottom: 0.5rem;
    }
    .health-excellent {
      color: var(--color-ok);
    }
    .health-good {
      color: #22c55e;
    }
    .health-fair {
      color: var(--color-warn);
    }
    .health-poor {
      color: var(--color-fail);
    }
    .health-label {
      font-size: 1rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .stat-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 0.75rem;
    }
    .stat-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.5rem 0.75rem;
      background-color: var(--color-bg);
      border-radius: 0.375rem;
    }
    .stat-label {
      font-size: 0.875rem;
      color: var(--color-text-secondary);
    }
    .stat-value {
      font-size: 1.125rem;
      font-weight: 700;
    }
    .top-issues {
      background-color: var(--color-surface);
      border: 1px solid var(--color-border);
      border-radius: 0.5rem;
      padding: 1.25rem;
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05);
    }
    .top-issues h3 {
      font-size: 0.875rem;
      font-weight: 600;
      color: var(--color-text-secondary);
      margin-bottom: 1rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .issue-item {
      display: flex;
      gap: 0.75rem;
      padding: 0.75rem;
      margin-bottom: 0.75rem;
      background-color: var(--color-fail-bg);
      border-left: 4px solid var(--color-fail);
      border-radius: 0.375rem;
    }
    .issue-item:last-child {
      margin-bottom: 0;
    }
    .issue-number {
      flex-shrink: 0;
      width: 1.75rem;
      height: 1.75rem;
      display: flex;
      align-items: center;
      justify-content: center;
      background-color: var(--color-fail);
      color: white;
      border-radius: 50%;
      font-weight: 700;
      font-size: 0.875rem;
    }
    .issue-text {
      flex: 1;
      font-size: 0.875rem;
      line-height: 1.5;
      color: var(--color-text);
    }
    .no-issues {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 1rem;
      background-color: var(--color-ok-bg);
      border-left: 4px solid var(--color-ok);
      border-radius: 0.375rem;
      color: var(--color-ok);
      font-weight: 600;
    }

    /* ========================================
       Print Styles
       ======================================== */
    @media print {
      /* Base print styles */
      body {
        background: #ffffff;
        color: #000000;
        font-size: 11pt;
        line-height: 1.5;
      }

      /* Header and footer */
      .header {
        box-shadow: none;
        border-bottom: 2px solid #000000;
        padding: 0.5cm 1cm;
        margin-bottom: 0.5cm;
      }

      .header h1 {
        color: #000000;
        font-size: 18pt;
      }

      .header .subtitle {
        font-size: 10pt;
        color: #333333;
      }

      .footer {
        border-top: 1px solid #000000;
        padding: 0.25cm 0;
        font-size: 9pt;
        break-before: auto;
      }

      /* Container adjustments */
      .container {
        max-width: 100%;
        padding: 0.5cm 1cm;
      }

      /* Hide interactive elements */
      .expand-collapse-all {
        display: none !important;
      }

      .btn {
        display: none !important;
      }

      /* Executive summary */
      .executive-summary {
        background: #ffffff;
        border: 2px solid #000000;
        box-shadow: none;
        padding: 0.5cm;
        margin-bottom: 0.5cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .executive-summary h2 {
        font-size: 14pt;
        color: #000000;
        border-bottom-color: #000000;
        margin-bottom: 0.3cm;
      }

      .summary-grid {
        grid-template-columns: 1fr 1fr;
        gap: 0.3cm;
      }

      .summary-card {
        box-shadow: none;
        border: 1px solid #cccccc;
        padding: 0.3cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .summary-card h3 {
        font-size: 9pt;
        color: #666666;
      }

      .health-score {
        font-size: 24pt;
      }

      .health-excellent,
      .health-good,
      .health-fair,
      .health-poor {
        color: #000000;
      }

      .stat-item {
        background-color: #f5f5f5;
        padding: 0.15cm 0.2cm;
      }

      .stat-label {
        font-size: 9pt;
        color: #666666;
      }

      .stat-value {
        font-size: 11pt;
        color: #000000;
      }

      /* Top issues section */
      .top-issues {
        box-shadow: none;
        border: 1px solid #cccccc;
        padding: 0.3cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .top-issues h3 {
        font-size: 9pt;
        color: #666666;
      }

      .issue-item {
        background-color: #f5f5f5;
        border-left-color: #666666;
        margin-bottom: 0.2cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .issue-number {
        background-color: #666666;
      }

      .issue-text {
        font-size: 9pt;
      }

      .no-issues {
        background-color: #f0f0f0;
        border-left-color: #666666;
        color: #000000;
      }

      /* Section styles */
      .section {
        box-shadow: none;
        border: 1px solid #cccccc;
        margin-bottom: 0.4cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .section.severity-ok {
        border-left: 3px solid #666666;
      }

      .section.severity-warn {
        border-left: 3px solid #333333;
      }

      .section.severity-fail {
        border-left: 3px solid #000000;
        border-left-width: 4px;
      }

      .section.severity-info {
        border-left: 3px solid #999999;
      }

      /* Force all sections to be expanded in print */
      .section.collapsed .section-content {
        max-height: none !important;
        padding: 0 0.4cm 0.4cm 0.4cm !important;
      }

      .section-header {
        padding: 0.3cm 0.4cm;
        cursor: default;
        background-color: #ffffff;
      }

      .section-header:hover {
        background-color: #ffffff;
      }

      .section-title {
        font-size: 12pt;
        color: #000000;
      }

      /* Hide toggle icons in print */
      .toggle-icon {
        display: none !important;
      }

      .section-content {
        padding: 0 0.4cm 0.4cm 0.4cm;
      }

      /* Severity badges */
      .severity-badge {
        font-size: 8pt;
        padding: 0.1cm 0.2cm;
      }

      .severity-badge.ok {
        background-color: #e0e0e0;
        color: #000000;
      }

      .severity-badge.warn {
        background-color: #d0d0d0;
        color: #000000;
        border: 1px solid #999999;
      }

      .severity-badge.fail {
        background-color: #c0c0c0;
        color: #000000;
        border: 1px solid #666666;
      }

      .severity-badge.info {
        background-color: #e8e8e8;
        color: #000000;
      }

      /* Item rows */
      .item {
        padding: 0.2cm 0;
        border-bottom: 1px solid #dddddd;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .item-label {
        font-size: 10pt;
        color: #000000;
      }

      .item-value {
        font-size: 10pt;
        color: #333333;
      }

      .item-status {
        font-size: 9pt;
      }

      .status-ok {
        background-color: #e0e0e0;
        color: #000000;
      }

      .status-warn {
        background-color: #d0d0d0;
        color: #000000;
        border: 1px solid #999999;
      }

      .status-fail {
        background-color: #c0c0c0;
        color: #000000;
        border: 1px solid #666666;
      }

      .status-info {
        background-color: #e8e8e8;
        color: #000000;
      }

      /* Summary and error boxes */
      .summary-box {
        background-color: #f5f5f5;
        border-left-color: #666666;
        padding: 0.3cm;
        margin-bottom: 0.3cm;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      .summary-box ul {
        margin-left: 0.5cm;
      }

      .error-log {
        background-color: #f5f5f5;
        border-left-color: #333333;
        padding: 0.3cm;
        font-size: 9pt;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      /* Code blocks */
      pre {
        background-color: #f8f8f8;
        border: 1px solid #cccccc;
        padding: 0.2cm;
        font-size: 9pt;
        break-inside: avoid;
        page-break-inside: avoid;
      }

      /* Ensure good page breaks */
      h1, h2, h3, h4, h5, h6 {
        break-after: avoid;
        page-break-after: avoid;
      }

      /* Remove unnecessary margins for print density */
      * {
        box-shadow: none !important;
      }
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>AD Login Speed Diagnostic Report</h1>
    <div class="subtitle">Generated: {{TIMESTAMP}}</div>
    <div class="subtitle">Hostname: {{HOSTNAME}} | Quick Mode: {{QUICKMODE}} | Domain Joined: {{DOMAINJOINED}}</div>
  </div>
  <div class="container">
    <div class="expand-collapse-all">
      <button class="btn" onclick="expandAll()">Expand All</button>
      <button class="btn" onclick="collapseAll()">Collapse All</button>
    </div>
    {{CONTENT}}
  </div>
  <div class="footer">
    <p>AD Login Speed Diagnostic Script &copy; 2024</p>
  </div>
  <script>
    function toggleSection(element) {
      const section = element.closest('.section');
      section.classList.toggle('collapsed');
    }

    function expandAll() {
      document.querySelectorAll('.section.collapsed').forEach(section => {
        section.classList.remove('collapsed');
      });
    }

    function collapseAll() {
      document.querySelectorAll('.section:not(.collapsed)').forEach(section => {
        section.classList.add('collapsed');
      });
    }

    document.addEventListener('DOMContentLoaded', function() {
      document.querySelectorAll('.section-header').forEach(header => {
        header.addEventListener('click', function() {
          toggleSection(this);
        });
      });
    });
  </script>
</body>
</html>
'@
}

function New-ExecutiveSummary {
    param(
        [System.Collections.Generic.List[string]]$ReportLines,
        [System.Collections.Generic.List[string]]$DiagnosticSummary,
        [System.Collections.Generic.List[string]]$Warnings,
        [System.Collections.Generic.List[PSCustomObject]]$ErrorLog
    )

    # Count status occurrences from report lines
    $statusCounts = @{
        OK = 0
        WARN = 0
        FAIL = 0
        INFO = 0
    }

    foreach ($line in $ReportLines) {
        if ($line -match '^\s+\[(OK|WARN|FAIL|INFO)\]\s+') {
            $status = $Matches[1]
            $statusCounts[$status]++
        }
    }

    # Calculate health score (0-100)
    $totalChecks = $statusCounts.OK + $statusCounts.WARN + $statusCounts.FAIL
    if ($totalChecks -eq 0) { $totalChecks = 1 }  # Avoid division by zero

    $healthScore = [math]::Round(
        (($statusCounts.OK * 100) + ($statusCounts.WARN * 50) + ($statusCounts.FAIL * 0)) / $totalChecks
    )

    # Determine health status and color
    $healthStatus = if ($healthScore -ge 90) {
        @{ Label = "Excellent"; Class = "health-excellent" }
    } elseif ($healthScore -ge 70) {
        @{ Label = "Good"; Class = "health-good" }
    } elseif ($healthScore -ge 50) {
        @{ Label = "Fair"; Class = "health-fair" }
    } else {
        @{ Label = "Poor"; Class = "health-poor" }
    }

    # Get top 3 issues (prioritize FAIL warnings, then other warnings, then diagnostic summary)
    $topIssues = @()
    $failWarnings = $Warnings | Where-Object { $_ -match '\[FAIL\]' } | Select-Object -First 3
    $topIssues += $failWarnings

    if ($topIssues.Count -lt 3) {
        $warnWarnings = $Warnings | Where-Object { $_ -match '\[WARN\]' } | Select-Object -First (3 - $topIssues.Count)
        $topIssues += $warnWarnings
    }

    if ($topIssues.Count -lt 3) {
        $diagIssues = $DiagnosticSummary | Select-Object -First (3 - $topIssues.Count)
        $topIssues += $diagIssues
    }

    # Clean up issue text (remove status tags)
    $topIssues = $topIssues | ForEach-Object {
        $_ -replace '^\s*\[(?:OK|WARN|FAIL|INFO)\]\s+', ''
    }

    # Build HTML
    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("<div class='executive-summary'>") | Out-Null
    $sb.AppendLine("  <h2>Executive Summary</h2>") | Out-Null
    $sb.AppendLine("  <div class='summary-grid'>") | Out-Null

    # Health Score Card
    $sb.AppendLine("    <div class='summary-card'>") | Out-Null
    $sb.AppendLine("      <h3>Overall Health Score</h3>") | Out-Null
    $sb.AppendLine("      <div class='health-score $($healthStatus.Class)'>$healthScore</div>") | Out-Null
    $sb.AppendLine("      <div class='health-label $($healthStatus.Class)'>$($healthStatus.Label)</div>") | Out-Null
    $sb.AppendLine("    </div>") | Out-Null

    # Statistics Card
    $sb.AppendLine("    <div class='summary-card'>") | Out-Null
    $sb.AppendLine("      <h3>Diagnostic Statistics</h3>") | Out-Null
    $sb.AppendLine("      <div class='stat-grid'>") | Out-Null
    $sb.AppendLine("        <div class='stat-item'>") | Out-Null
    $sb.AppendLine("          <span class='stat-label'>Passed</span>") | Out-Null
    $sb.AppendLine("          <span class='stat-value' style='color: var(--color-ok);'>$($statusCounts.OK)</span>") | Out-Null
    $sb.AppendLine("        </div>") | Out-Null
    $sb.AppendLine("        <div class='stat-item'>") | Out-Null
    $sb.AppendLine("          <span class='stat-label'>Warnings</span>") | Out-Null
    $sb.AppendLine("          <span class='stat-value' style='color: var(--color-warn);'>$($statusCounts.WARN)</span>") | Out-Null
    $sb.AppendLine("        </div>") | Out-Null
    $sb.AppendLine("        <div class='stat-item'>") | Out-Null
    $sb.AppendLine("          <span class='stat-label'>Failures</span>") | Out-Null
    $sb.AppendLine("          <span class='stat-value' style='color: var(--color-fail);'>$($statusCounts.FAIL)</span>") | Out-Null
    $sb.AppendLine("        </div>") | Out-Null
    $sb.AppendLine("        <div class='stat-item'>") | Out-Null
    $sb.AppendLine("          <span class='stat-label'>Info</span>") | Out-Null
    $sb.AppendLine("          <span class='stat-value' style='color: var(--color-info);'>$($statusCounts.INFO)</span>") | Out-Null
    $sb.AppendLine("        </div>") | Out-Null
    $sb.AppendLine("      </div>") | Out-Null
    $sb.AppendLine("    </div>") | Out-Null
    $sb.AppendLine("  </div>") | Out-Null

    # Top Issues Section
    $sb.AppendLine("  <div class='top-issues'>") | Out-Null
    $sb.AppendLine("    <h3>Top Issues Detected</h3>") | Out-Null

    if ($topIssues.Count -eq 0) {
        $sb.AppendLine("    <div class='no-issues'>") | Out-Null
        $sb.AppendLine("      <svg width='20' height='20' viewBox='0 0 20 20' fill='currentColor'>") | Out-Null
        $sb.AppendLine("        <path fill-rule='evenodd' d='M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z' clip-rule='evenodd'/>") | Out-Null
        $sb.AppendLine("      </svg>") | Out-Null
        $sb.AppendLine("      <span>No critical issues detected</span>") | Out-Null
        $sb.AppendLine("    </div>") | Out-Null
    } else {
        for ($i = 0; $i -lt $topIssues.Count; $i++) {
            $issueText = ConvertTo-HtmlEscaped $topIssues[$i]
            $sb.AppendLine("    <div class='issue-item'>") | Out-Null
            $sb.AppendLine("      <div class='issue-number'>$($i + 1)</div>") | Out-Null
            $sb.AppendLine("      <div class='issue-text'>$issueText</div>") | Out-Null
            $sb.AppendLine("    </div>") | Out-Null
        }
    }

    $sb.AppendLine("  </div>") | Out-Null
    $sb.AppendLine("</div>") | Out-Null

    return $sb.ToString()
}

function ConvertTo-HtmlReport {
    param(
        [System.Collections.Generic.List[string]]$ReportLines,
        [System.Collections.Generic.List[string]]$DiagnosticSummary,
        [System.Collections.Generic.List[PSCustomObject]]$ErrorLog,
        [System.Collections.Generic.List[string]]$Warnings,
        [hashtable]$SectionStatus,
        [string]$Hostname,
        [string]$RunTime,
        [bool]$IsQuickMode,
        [bool]$IsDomainJoined
    )

    $html = Get-HtmlTemplate

    # Replace metadata
    $html = $html.Replace("{{TIMESTAMP}}", (ConvertTo-HtmlEscaped $RunTime))
    $html = $html.Replace("{{HOSTNAME}}", (ConvertTo-HtmlEscaped $Hostname))
    $html = $html.Replace("{{QUICKMODE}}", $(if ($IsQuickMode) { "ENABLED" } else { "DISABLED" }))
    $html = $html.Replace("{{DOMAINJOINED}}", $(if ($IsDomainJoined) { "Yes" } else { "No" }))

    # Build content from report lines
    $contentBuilder = [System.Text.StringBuilder]::new()

    # Insert executive summary at the top
    $executiveSummaryHtml = New-ExecutiveSummary `
        -ReportLines $ReportLines `
        -DiagnosticSummary $DiagnosticSummary `
        -Warnings $Warnings `
        -ErrorLog $ErrorLog
    $contentBuilder.AppendLine($executiveSummaryHtml) | Out-Null

    $currentSection = $null
    $inSection = $false
    $sectionContent = [System.Text.StringBuilder]::new()

    foreach ($line in $ReportLines) {
        # Skip the header box
        if ($line -match "^╔═+╗$|^║.*║$|^╚═+╝$") {
            continue
        }

        # Detect section headers
        if ($line -match "^={70}$") {
            continue
        }
        if ($line -match "^\s+(.+)$" -and $ReportLines[$ReportLines.IndexOf($line) - 1] -match "^={70}$") {
            # Close previous section
            if ($inSection) {
                $contentBuilder.AppendLine("</div>") | Out-Null
                $contentBuilder.AppendLine("</div>") | Out-Null
            }

            # Start new section
            $sectionTitle = $Matches[1].Trim()
            $currentSection = $sectionTitle
            $severity = Get-SectionSeverity -SectionTitle $sectionTitle -ReportLines $ReportLines -SectionStatus $SectionStatus

            # Section container with severity class
            $contentBuilder.AppendLine("<div class='section severity-$severity'>") | Out-Null

            # Section header (clickable)
            $contentBuilder.AppendLine("  <div class='section-header' role='button' aria-expanded='true'>") | Out-Null
            $contentBuilder.AppendLine("    <div class='section-title'>") | Out-Null
            $contentBuilder.AppendLine("      <span>$(ConvertTo-HtmlEscaped $sectionTitle)</span>") | Out-Null
            $contentBuilder.AppendLine("      <span class='severity-badge $severity'>$($severity.ToUpper())</span>") | Out-Null
            $contentBuilder.AppendLine("    </div>") | Out-Null
            $contentBuilder.AppendLine("    <svg class='toggle-icon' viewBox='0 0 20 20' fill='currentColor'>") | Out-Null
            $contentBuilder.AppendLine("      <path fill-rule='evenodd' d='M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z' clip-rule='evenodd'/>") | Out-Null
            $contentBuilder.AppendLine("    </svg>") | Out-Null
            $contentBuilder.AppendLine("  </div>") | Out-Null

            # Section content (collapsible)
            $contentBuilder.AppendLine("  <div class='section-content'>") | Out-Null

            $inSection = $true
            continue
        }

        # Parse item lines: [STATUS] Label Value
        if ($line -match '^\s+\[(\w+)\]\s+(.{40})\s+(.+)$') {
            $status = $Matches[1].Trim()
            $label = $Matches[2].Trim()
            $value = $Matches[3].Trim()
            $statusClass = Get-StatusClass $status

            $contentBuilder.AppendLine("<div class='item'>") | Out-Null
            $contentBuilder.AppendLine("  <div class='item-label'>$(ConvertTo-HtmlEscaped $label)</div>") | Out-Null
            $contentBuilder.AppendLine("  <div class='item-value'>$(ConvertTo-HtmlEscaped $value)</div>") | Out-Null
            $contentBuilder.AppendLine("  <div class='item-status $statusClass'>$status</div>") | Out-Null
            $contentBuilder.AppendLine("</div>") | Out-Null
        }
        # Regular text lines
        elseif ($line.Trim() -ne "" -and -not ($line -match "^Quick Mode:|^Sections:")) {
            $escapedLine = ConvertTo-HtmlEscaped $line
            if ($line -match "^\s{2}[^\s]") {
                $contentBuilder.AppendLine("<div style='margin-top:0.5rem; color: var(--color-text-secondary);'>$escapedLine</div>") | Out-Null
            }
        }
    }

    # Close last section
    if ($inSection) {
        $contentBuilder.AppendLine("  </div>") | Out-Null
        $contentBuilder.AppendLine("</div>") | Out-Null
    }

    # Add diagnostic summary if present
    if ($DiagnosticSummary.Count -gt 0) {
        $contentBuilder.AppendLine("<div class='section severity-info'>") | Out-Null
        $contentBuilder.AppendLine("  <div class='section-header' role='button' aria-expanded='true'>") | Out-Null
        $contentBuilder.AppendLine("    <div class='section-title'>") | Out-Null
        $contentBuilder.AppendLine("      <span>Diagnostic Summary</span>") | Out-Null
        $contentBuilder.AppendLine("      <span class='severity-badge info'>INFO</span>") | Out-Null
        $contentBuilder.AppendLine("    </div>") | Out-Null
        $contentBuilder.AppendLine("    <svg class='toggle-icon' viewBox='0 0 20 20' fill='currentColor'>") | Out-Null
        $contentBuilder.AppendLine("      <path fill-rule='evenodd' d='M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z' clip-rule='evenodd'/>") | Out-Null
        $contentBuilder.AppendLine("    </svg>") | Out-Null
        $contentBuilder.AppendLine("  </div>") | Out-Null
        $contentBuilder.AppendLine("  <div class='section-content'>") | Out-Null
        $contentBuilder.AppendLine("    <div class='summary-box'>") | Out-Null
        $contentBuilder.AppendLine("      <ul>") | Out-Null
        foreach ($item in $DiagnosticSummary) {
            $contentBuilder.AppendLine("        <li>$(ConvertTo-HtmlEscaped $item)</li>") | Out-Null
        }
        $contentBuilder.AppendLine("      </ul>") | Out-Null
        $contentBuilder.AppendLine("    </div>") | Out-Null
        $contentBuilder.AppendLine("  </div>") | Out-Null
        $contentBuilder.AppendLine("</div>") | Out-Null
    }

    $html = $html.Replace("{{CONTENT}}", $contentBuilder.ToString())
    return $html
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

# Display Quick Mode and Section Filter status
$quickModeText = "Quick Mode: $(if ($Quick) { 'ENABLED' } else { 'DISABLED' })"
Write-Raw $quickModeText

if ($null -ne $Sections -and $Sections.Count -gt 0) {
    $sectionsText = "Sections: $($Sections -join ', ')"
    Write-Raw $sectionsText
}

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
if (Test-ShouldRunSection -SectionNumber 1) {
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
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 – LOCAL DEVICE PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 2) {
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
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3 – DNS AND DOMAIN CONTROLLER DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 3) {
Write-Section "3. DNS & DOMAIN CONTROLLER DISCOVERY"
$SectionStatus["3. DNS & DC Discovery"] = "In Progress"
$section3Errors = 0

if (-not $IsDomainJoined) {
    Write-Item "DNS & DC Discovery"  "N/A – machine is not domain-joined" "INFO"
    $SectionStatus["3. DNS & DC Discovery"] = "Skipped"
} else {
    $domain = $cs.Domain

    # DNS resolution of the domain
    $dnsResult = Measure-MSec {
        try {
            [System.Net.Dns]::GetHostAddresses($domain)
        } catch {
            Write-ErrorLog -Category "OperationError" -Source "Section 3 - DNS Resolution" `
                -Message "DNS resolution failed for '$domain': $($_.Exception.Message)" `
                -Remediation "Check DNS server configuration. Ensure the machine can reach a DNS server that knows the AD domain."
            $section3Errors++
            $null
        }
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
    # Wrapped in Invoke-WithTimeout to protect against hanging DC discovery
    $dcDiscResult = Measure-MSec {
        $dcResult = Invoke-WithTimeout -Source "Section 3 - DC Discovery" -TimeoutSeconds 30 -Block {
            try {
                $adContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new(
                    [System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $using:domain
                )
                $dc = [System.DirectoryServices.ActiveDirectory.DomainController]::FindOne($adContext)
                [pscustomobject]@{ Name = $dc.Name; SiteName = $dc.SiteName; Success = $true; Method = ".NET API" }
            } catch {
                # Fallback: nltest with structural parsing (parse by DC:\\ pattern, locale-resilient)
                try {
                    $out = & nltest.exe /dsgetdc:$using:domain 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $dcName = $null
                        $siteName = $null
                        foreach ($line in $out) {
                            if ($line -match '^\s*DC:\s*\\\\(.+)') {
                                $dcName = $Matches[1].Trim()
                            }
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
        if ($null -eq $dcResult) {
            $section3Errors++
            [pscustomobject]@{ Name = $null; SiteName = $null; Success = $false; Method = "timeout" }
        } else {
            $dcResult
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
        $section3Errors++
    }
}
$SectionStatus["3. DNS & DC Discovery"] = if ($SectionStatus["3. DNS & DC Discovery"] -eq "Skipped") { "Skipped" } elseif ($section3Errors -gt 0) { "Partial" } else { "Completed" }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4 – NETWORK CONNECTIVITY TO DOMAIN CONTROLLER
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 4) {
Write-Section "4. NETWORK CONNECTIVITY TO DOMAIN CONTROLLER"
$SectionStatus["4. Network Connectivity"] = "In Progress"
$section4Errors = 0

if (-not $IsDomainJoined) {
    Write-Item "DC Network Connectivity"  "N/A – machine is not domain-joined" "INFO"
    $SectionStatus["4. Network Connectivity"] = "Skipped"
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

        # Set TCP timeout: 1 second in Quick mode, 5 seconds otherwise
        $tcpTimeoutMs = if ($Quick) { 1000 } else { 5000 }

        foreach ($p in $ports) {
            $connResult = Measure-MSec {
                $tcp = New-Object System.Net.Sockets.TcpClient
                try {
                    # Use async connect with timeout
                    $connectTask = $tcp.BeginConnect($script:DC, $p.Port, $null, $null)
                    $success = $connectTask.AsyncWaitHandle.WaitOne($tcpTimeoutMs, $false)
                    if ($success) {
                        $tcp.EndConnect($connectTask)
                        $tcp.Connected
                    } else {
                        $false
                    }
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

        # SMB / SYSVOL share availability (with timeout protection)
        $sysvolDC = $script:DC
        $sysvolResult = Measure-MSec {
            $testResult = Invoke-WithTimeout -Source "Section 4 - SYSVOL Test" -TimeoutSeconds 30 -Block {
                Test-Path "\\$using:sysvolDC\SYSVOL" -ErrorAction SilentlyContinue
            }
            if ($null -eq $testResult) {
                $section4Errors++
                $false
            } else {
                $testResult
            }
        }
        $sysvolStatus = if ($sysvolResult.Result) {
                            if ($sysvolResult.Ms -gt 3000) { "WARN" } else { "OK" }
                        } else { "FAIL" }
        Write-Item "SYSVOL share reachable"  $(if ($sysvolResult.Result) { "Yes ($($sysvolResult.Ms) ms)" } else { "No" }) $sysvolStatus
        if (-not $sysvolResult.Result) {
            $DiagnosticSummary.Add("SYSVOL is not reachable. GPOs and logon scripts cannot be applied from $($script:DC).")
            $section4Errors++
        }
    }
}
$SectionStatus["4. Network Connectivity"] = if ($SectionStatus["4. Network Connectivity"] -eq "Skipped") { "Skipped" } elseif ($section4Errors -gt 0) { "Partial" } else { "Completed" }

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
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 5 – GROUP POLICY PROCESSING TIMES (EVENT LOG)
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 5) {
Write-Section "5. GROUP POLICY PROCESSING TIMES (Last 5 logons)"
$SectionStatus["5. Group Policy Processing"] = "In Progress"

if (-not $IsDomainJoined) {
    Write-Item "Group Policy"  "N/A – machine is not domain-joined" "INFO"
    $SectionStatus["5. Group Policy Processing"] = "Skipped"
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

if ($SectionStatus["5. Group Policy Processing"] -ne "Skipped") {
    $SectionStatus["5. Group Policy Processing"] = if ($ErrorLog | Where-Object { $_.Source -like "*Section 5*" }) { "Partial" } else { "Completed" }
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
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 6 – LOGON EVENT TIMING (Security Event Log)
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 6) {
Write-Section "6. RECENT INTERACTIVE LOGON EVENTS"
$SectionStatus["6. Logon Events"] = "In Progress"

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

$SectionStatus["6. Logon Events"] = if (-not $IsAdmin) { "Skipped" } elseif ($ErrorLog | Where-Object { $_.Source -like "*Section 6*" }) { "Partial" } else { "Completed" }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 7 – USER PROFILE
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 7) {
Write-Section "7. USER PROFILE"
$SectionStatus["7. User Profile"] = "In Progress"

try {
    # Without admin, Win32_UserProfile only returns the current user's profile
    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
                Where-Object { -not $_.Special } |
                Sort-Object LastUseTime -Descending

    if (-not $IsAdmin) {
        Write-Item "Profile enumeration"  "Running as standard user – showing current user profile only" "WARN"
    }

    if ($Quick) {
        Write-Item "Profile enumeration" "Skipped (Quick Mode)" "INFO"
    } else {
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
    }
} catch {
    $category = if ($_.Exception.Message -match "Access.denied|not have permission") { "SecurityFailure" } else { "OperationError" }
    Write-ErrorLog -Category $category -Source "Section 7 - User Profile" `
        -Message "Failed to retrieve user profiles via CIM: $($_.Exception.Message)" `
        -Remediation "Ensure the WMI/CIM service (winmgmt) is running and Win32_UserProfile class is accessible."
}

$SectionStatus["7. User Profile"] = if ($ErrorLog | Where-Object { $_.Source -like "*Section 7*" }) { "Partial" } else { "Completed" }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 8 – LOGON SCRIPTS
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 8) {
Write-Section "8. LOGON SCRIPTS & STARTUP ITEMS"
$SectionStatus["8. Logon Scripts"] = "In Progress"

# Check for logon scripts via Group Policy registry keys
$gpoLogonScripts = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Startup",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\User\Scripts\Logon"
)

$foundScripts = $false
try {
    foreach ($regPath in $gpoLogonScripts) {
        if (Test-Path $regPath) {
            $scripts = Get-ChildItem $regPath -ErrorAction Stop
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
} catch {
    $category = if ($_.Exception.Message -match "Access.denied|not have permission") { "SecurityFailure" } else { "OperationError" }
    Write-ErrorLog -Category $category -Source "Section 8 - GP Scripts Registry" `
        -Message "Failed to enumerate GP logon scripts from registry: $($_.Exception.Message)" `
        -Remediation "Ensure you have read access to the Group Policy registry keys under HKLM/HKCU."
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

$SectionStatus["8. Logon Scripts"] = if ($ErrorLog | Where-Object { $_.Source -like "*Section 8*" }) { "Partial" } else { "Completed" }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 9 – WINDOWS LOGON PERFORMANCE (Winlogon event channel)
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 9) {
Write-Section "9. WINDOWS LOGON PERFORMANCE EVENTS"
$SectionStatus["9. Winlogon Performance"] = "In Progress"

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

$SectionStatus["9. Winlogon Performance"] = if (-not $IsAdmin) { "Skipped" } elseif ($ErrorLog | Where-Object { $_.Source -like "*Section 9*" }) { "Partial" } else { "Completed" }
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 10 – NETLOGON LOG ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 10) {
Write-Section "10. NETLOGON LOG ANALYSIS"
$SectionStatus["10. Netlogon Analysis"] = "In Progress"

if (-not $IsDomainJoined) {
    Write-Item "NETLOGON Log"  "N/A – machine is not domain-joined" "INFO"
    $SectionStatus["10. Netlogon Analysis"] = "Skipped"
}

try {
    $netlogonPath = "$env:SystemRoot\debug\netlogon.log"
    if (Test-Path $netlogonPath) {
        # Netlogon.log is written by the system in OEM codepage (e.g., CP932/Shift-JIS on Japanese Windows)
        $systemEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $netlogon = Get-Content $netlogonPath -Encoding $systemEncoding -ErrorAction Stop | Select-Object -Last 300
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
} catch {
    $category = if ($_.Exception.Message -match "Access.denied|not have permission|UnauthorizedAccess") { "SecurityFailure" } else { "OperationError" }
    Write-ErrorLog -Category $category -Source "Section 10 - Netlogon Analysis" `
        -Message "Failed to read netlogon log: $($_.Exception.Message)" `
        -Remediation "Ensure you have read access to $env:SystemRoot\debug\netlogon.log. Run as administrator if needed."
}

if ($SectionStatus["10. Netlogon Analysis"] -ne "Skipped") {
    $SectionStatus["10. Netlogon Analysis"] = if ($ErrorLog | Where-Object { $_.Source -like "*Section 10*" }) { "Partial" } else { "Completed" }
}
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 11 – DIAGNOSTIC SUMMARY & RECOMMENDATIONS
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 11) {
Write-Section "11. DIAGNOSTIC SUMMARY & RECOMMENDATIONS"
$SectionStatus["11. Summary & Recommendations"] = "In Progress"

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

$SectionStatus["11. Summary & Recommendations"] = "Completed"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 12 – ERROR LOG
# ═══════════════════════════════════════════════════════════════════════════
if (Test-ShouldRunSection -SectionNumber 12) {
Write-Section "12. ERROR LOG"
$SectionStatus["12. Error Log"] = "In Progress"

# ─── Section Status Summary Table ───────────────────────────────────────────
Write-Raw ""
Write-Raw "  ┌─────────────────────────────────────────────────────────────┐"
Write-Raw "  │                    SECTION STATUS SUMMARY                   │"
Write-Raw "  ├──────────────────────────────────────────┬──────────────────┤"
Write-Raw "  │ Section                                  │ Status           │"
Write-Raw "  ├──────────────────────────────────────────┼──────────────────┤"
foreach ($key in $SectionStatus.Keys) {
    if ($key -eq "12. Error Log") { continue }
    $statusVal = $SectionStatus[$key]
    $sectionCol = Format-FixedWidth $key 40
    $statusCol  = Format-FixedWidth $statusVal 16
    Write-Raw "  │ $sectionCol │ $statusCol │"
}
Write-Raw "  └──────────────────────────────────────────┴──────────────────┘"
Write-Raw ""

# ─── Error Counts by Category ──────────────────────────────────────────────
if ($ErrorLog.Count -gt 0) {
    Write-Raw "  Error Counts by Category:"
    Write-Raw "  ─────────────────────────────────────────"
    $grouped = $ErrorLog | Group-Object -Property Category | Sort-Object Count -Descending
    foreach ($g in $grouped) {
        Write-Raw ("  {0,-30} {1}" -f $g.Name, $g.Count)
    }
    Write-Raw ""

    # ─── Remediation Guidance ───────────────────────────────────────────────
    $remediationCategories = @("MissingCommand", "MissingModule", "MissingType", "SecurityFailure", "EnvironmentIssue")
    $remediationErrors = $ErrorLog | Where-Object { $_.Category -in $remediationCategories -and $_.Remediation }
    if ($remediationErrors) {
        Write-Raw "  ╔═══════════════════════════════════════════════════════════════╗"
        Write-Raw "  ║              REMEDIATION GUIDANCE                             ║"
        Write-Raw "  ╚═══════════════════════════════════════════════════════════════╝"
        Write-Raw ""
        $remGroups = $remediationErrors | Group-Object -Property Category
        foreach ($rg in $remGroups) {
            Write-Raw "  [$($rg.Name)]"
            foreach ($entry in $rg.Group) {
                Write-Raw "    • $($entry.Source): $($entry.Remediation)"
            }
            Write-Raw ""
        }
    }

    # ─── Error Entries ──────────────────────────────────────────────────────
    Write-Raw "  All Error Entries ($($ErrorLog.Count)):"
    Write-Raw "  ─────────────────────────────────────────"
    foreach ($entry in $ErrorLog) {
        Write-Raw "  Timestamp   : $($entry.Timestamp)"
        Write-Raw "  Category    : $($entry.Category)"
        Write-Raw "  Source      : $($entry.Source)"
        Write-Raw "  Message     : $($entry.Message)"
        if ($entry.Remediation) {
            Write-Raw "  Remediation : $($entry.Remediation)"
        }
        Write-Raw ""
    }
} else {
    Write-Raw "  No errors were recorded during diagnostics."
    Write-Raw ""
}

$SectionStatus["12. Error Log"] = "Completed"
}

# ─── Save Report ────────────────────────────────────────────────────────────

$ReportLines | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Host "`nReport written to: $OutputPath" -ForegroundColor Green

# Create _latest copy for quick access
$LatestPath = Join-Path (Split-Path $OutputPath -Parent) "LoginSpeedReport_latest.txt"
Copy-Item -Path $OutputPath -Destination $LatestPath -Force
Write-Host "Latest copy written to: $LatestPath" -ForegroundColor Green

# ─── Generate HTML Report (unless -NoHtml specified) ───────────────────────
if (-not $NoHtml) {
    $HtmlPath = $OutputPath -replace '\.txt$', '.html'
    try {
        $htmlContent = ConvertTo-HtmlReport `
            -ReportLines $ReportLines `
            -DiagnosticSummary $DiagnosticSummary `
            -ErrorLog $ErrorLog `
            -Warnings $Warnings `
            -SectionStatus $SectionStatus `
            -Hostname $env:COMPUTERNAME `
            -RunTime $RunTime `
            -IsQuickMode $Quick `
            -IsDomainJoined $IsDomainJoined

        $htmlContent | Out-File -FilePath $HtmlPath -Encoding UTF8 -Force
        Write-Host "HTML report written to: $HtmlPath" -ForegroundColor Green

        # Create _latest copy for quick access
        $LatestHtmlPath = Join-Path (Split-Path $HtmlPath -Parent) "LoginSpeedReport_latest.html"
        Copy-Item -Path $HtmlPath -Destination $LatestHtmlPath -Force
    } catch {
        Write-Host "Warning: Could not generate HTML report: $_" -ForegroundColor Yellow
    }
}

# ─── JSON Error Log Export ─────────────────────────────────────────────────
$JsonPath = $OutputPath -replace '\.txt$', '_errors.json'
try {
    $jsonExport = [ordered]@{
        metadata = [ordered]@{
            timestamp     = $RunTime
            hostname      = $env:COMPUTERNAME
            psVersion     = $PSVersionTable.PSVersion.ToString()
            psEdition     = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { "Desktop" }
            languageMode  = $ExecutionContext.SessionState.LanguageMode.ToString()
            isAdmin       = $IsAdmin
            isDomainJoined = $IsDomainJoined
        }
        sectionStatus = $SectionStatus
        errors        = @($ErrorLog)
    }
    $jsonExport | ConvertTo-Json -Depth 4 | Out-File -FilePath $JsonPath -Encoding UTF8 -Force
    Write-Host "JSON error log written to: $JsonPath" -ForegroundColor Green

    # Create _latest copy for quick access
    $LatestJsonPath = Join-Path (Split-Path $JsonPath -Parent) "LoginSpeedReport_latest_errors.json"
    Copy-Item -Path $JsonPath -Destination $LatestJsonPath -Force
} catch {
    Write-Host "Could not write JSON error log to ${JsonPath}: $_" -ForegroundColor Yellow
}

# ─── Encoding Cleanup ───────────────────────────────────────────────────────
# Restore the user's original encoding settings so the script leaves no
# side effects on the PowerShell session.

[Console]::OutputEncoding = $OriginalConsoleOutputEncoding
$OutputEncoding           = $OriginalOutputEncoding
