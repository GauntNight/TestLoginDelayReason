# Manual Verification Tests for Timestamped Report Versioning

This document outlines the manual verification tests for the timestamped report versioning feature.

## Prerequisites
- Windows machine with Active Directory domain membership (for full diagnostic execution)
- PowerShell 5.1 or later
- Appropriate permissions to run diagnostic scripts

## Test Scenarios

### Scenario 1 & 2: Multiple Runs - Verify Timestamped Reports and _latest Copy

**Module Test (.psm1):**
```powershell
# Clean up any existing reports
Remove-Item -Path .\LoginSpeedReport*.* -ErrorAction SilentlyContinue

# Run diagnostic first time
Import-Module .\LoginSpeedDiagnostic.psm1 -Force
Invoke-LoginSpeedDiagnostic

# Wait a few seconds to ensure different timestamp
Start-Sleep -Seconds 2

# Run diagnostic second time
Invoke-LoginSpeedDiagnostic

# Verify results
$reports = Get-ChildItem -Filter "LoginSpeedReport_*.txt" | Where-Object { $_.Name -notlike "*_latest*" }
$latestReport = Get-ChildItem -Filter "LoginSpeedReport_latest.txt"

Write-Host "`n=== Verification Results ===" -ForegroundColor Cyan
Write-Host "Timestamped reports found: $($reports.Count)" -ForegroundColor $(if ($reports.Count -eq 2) { "Green" } else { "Red" })
Write-Host "Latest report exists: $($latestReport -ne $null)" -ForegroundColor $(if ($latestReport) { "Green" } else { "Red" })

if ($reports.Count -ge 2) {
    Write-Host "`nReport files:" -ForegroundColor Yellow
    $reports | ForEach-Object { Write-Host "  - $($_.Name) ($($_.LastWriteTime))" }
}

if ($latestReport) {
    Write-Host "`nLatest report:" -ForegroundColor Yellow
    Write-Host "  - $($latestReport.Name) ($($latestReport.LastWriteTime))"
    
    # Verify _latest copy matches most recent timestamped report
    $mostRecent = $reports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $latestContent = Get-Content $latestReport.FullName -Raw
    $mostRecentContent = Get-Content $mostRecent.FullName -Raw
    
    if ($latestContent -eq $mostRecentContent) {
        Write-Host "`n_latest copy matches most recent report: TRUE" -ForegroundColor Green
    } else {
        Write-Host "`n_latest copy matches most recent report: FALSE" -ForegroundColor Red
    }
}
```

**Standalone Script Test (.ps1):**
```powershell
# Clean up any existing reports
Remove-Item -Path .\LoginSpeedReport*.* -ErrorAction SilentlyContinue

# Run diagnostic first time
.\LoginSpeedDiagnostic.ps1

# Wait a few seconds to ensure different timestamp
Start-Sleep -Seconds 2

# Run diagnostic second time
.\LoginSpeedDiagnostic.ps1

# Verify results
$txtReports = Get-ChildItem -Filter "LoginSpeedReport_*.txt" | Where-Object { $_.Name -notlike "*_latest*" }
$htmlReports = Get-ChildItem -Filter "LoginSpeedReport_*.html" | Where-Object { $_.Name -notlike "*_latest*" }
$jsonReports = Get-ChildItem -Filter "LoginSpeedReport_*_errors.json" | Where-Object { $_.Name -notlike "*_latest*" }

$latestTxt = Get-ChildItem -Filter "LoginSpeedReport_latest.txt" -ErrorAction SilentlyContinue
$latestHtml = Get-ChildItem -Filter "LoginSpeedReport_latest.html" -ErrorAction SilentlyContinue
$latestJson = Get-ChildItem -Filter "LoginSpeedReport_latest_errors.json" -ErrorAction SilentlyContinue

Write-Host "`n=== Verification Results ===" -ForegroundColor Cyan
Write-Host "Timestamped TXT reports: $($txtReports.Count)" -ForegroundColor $(if ($txtReports.Count -eq 2) { "Green" } else { "Red" })
Write-Host "Timestamped HTML reports: $($htmlReports.Count)" -ForegroundColor $(if ($htmlReports.Count -eq 2) { "Green" } else { "Red" })
Write-Host "Timestamped JSON reports: $($jsonReports.Count)" -ForegroundColor $(if ($jsonReports.Count -eq 2) { "Green" } else { "Red" })
Write-Host "Latest TXT exists: $($latestTxt -ne $null)" -ForegroundColor $(if ($latestTxt) { "Green" } else { "Red" })
Write-Host "Latest HTML exists: $($latestHtml -ne $null)" -ForegroundColor $(if ($latestHtml) { "Green" } else { "Red" })
Write-Host "Latest JSON exists: $($latestJson -ne $null)" -ForegroundColor $(if ($latestJson) { "Green" } else { "Red" })
```

**Expected Results:**
- ✅ Two timestamped .txt reports with different timestamps
- ✅ Two timestamped .html reports (for .ps1 only)
- ✅ Two timestamped _errors.json files
- ✅ LoginSpeedReport_latest.txt exists and matches most recent report
- ✅ LoginSpeedReport_latest.html exists (for .ps1 only)
- ✅ LoginSpeedReport_latest_errors.json exists
- ✅ No files are overwritten (all previous reports remain)

---

### Scenario 3: -OutputPath with Directory

```powershell
# Create test directory
New-Item -Path ".\TestReports" -ItemType Directory -Force

# Run diagnostic with directory path
Import-Module .\LoginSpeedDiagnostic.psm1 -Force
Invoke-LoginSpeedDiagnostic -OutputPath ".\TestReports"

# Verify results
$reports = Get-ChildItem -Path ".\TestReports" -Filter "LoginSpeedReport_*.txt"
Write-Host "Reports in directory: $($reports.Count)" -ForegroundColor $(if ($reports.Count -gt 0) { "Green" } else { "Red" })
$reports | ForEach-Object { Write-Host "  - $($_.Name)" }
```

**Expected Results:**
- ✅ Report saved in .\TestReports\ directory
- ✅ Filename has timestamp: LoginSpeedReport_YYYYMMDD_HHmmss.txt
- ✅ _latest copy also created in .\TestReports\

---

### Scenario 4: -OutputPath with Custom Filename

```powershell
# Run diagnostic with custom filename
Import-Module .\LoginSpeedDiagnostic.psm1 -Force
Invoke-LoginSpeedDiagnostic -OutputPath ".\MyCustomReport.txt"

# Verify results
Test-Path ".\MyCustomReport.txt"
```

**Expected Results:**
- ✅ Report saved as .\MyCustomReport.txt (exact name specified)
- ✅ _latest copy still created as LoginSpeedReport_latest.txt in same directory
- ⚠️ Note: Custom filenames override the timestamp pattern

---

### Scenario 5: JSON Error Log Timestamping

```powershell
# Run diagnostic
Import-Module .\LoginSpeedDiagnostic.psm1 -Force
Invoke-LoginSpeedDiagnostic

# Check for JSON file
$jsonFiles = Get-ChildItem -Filter "LoginSpeedReport_*_errors.json" | Where-Object { $_.Name -notlike "*_latest*" }
$latestJson = Get-ChildItem -Filter "LoginSpeedReport_latest_errors.json"

Write-Host "Timestamped JSON files: $($jsonFiles.Count)" -ForegroundColor $(if ($jsonFiles.Count -gt 0) { "Green" } else { "Red" })
Write-Host "Latest JSON exists: $($latestJson -ne $null)" -ForegroundColor $(if ($latestJson) { "Green" } else { "Red" })

if ($jsonFiles.Count -gt 0) {
    $jsonFiles | ForEach-Object { 
        Write-Host "`nJSON file: $($_.Name)"
        $content = Get-Content $_.FullName | ConvertFrom-Json
        Write-Host "  Metadata timestamp: $($content.metadata.timestamp)"
        Write-Host "  Errors count: $($content.errors.Count)"
    }
}
```

**Expected Results:**
- ✅ JSON file has timestamp in filename: LoginSpeedReport_YYYYMMDD_HHmmss_errors.json
- ✅ LoginSpeedReport_latest_errors.json exists
- ✅ JSON contains metadata and error information

---

### Scenario 6: HTML Report Timestamping (.ps1 only)

```powershell
# Run standalone script
.\LoginSpeedDiagnostic.ps1

# Check for HTML file
$htmlFiles = Get-ChildItem -Filter "LoginSpeedReport_*.html" | Where-Object { $_.Name -notlike "*_latest*" }
$latestHtml = Get-ChildItem -Filter "LoginSpeedReport_latest.html"

Write-Host "Timestamped HTML files: $($htmlFiles.Count)" -ForegroundColor $(if ($htmlFiles.Count -gt 0) { "Green" } else { "Red" })
Write-Host "Latest HTML exists: $($latestHtml -ne $null)" -ForegroundColor $(if ($latestHtml) { "Green" } else { "Red" })

if ($htmlFiles.Count -gt 0) {
    $htmlFiles | ForEach-Object { 
        Write-Host "`nHTML file: $($_.Name) ($([Math]::Round($_.Length/1KB, 2)) KB)"
    }
}
```

**Expected Results:**
- ✅ HTML file has timestamp in filename: LoginSpeedReport_YYYYMMDD_HHmmss.html
- ✅ LoginSpeedReport_latest.html exists
- ✅ HTML file can be opened in browser and displays correctly

---

### Scenario 7: No Overwriting - Multiple Runs Preserve All Reports

```powershell
# Clean start
Remove-Item -Path .\LoginSpeedReport*.* -ErrorAction SilentlyContinue

# Run diagnostic 3 times with short delays
Import-Module .\LoginSpeedDiagnostic.psm1 -Force

1..3 | ForEach-Object {
    Write-Host "`n=== Run $_ ===" -ForegroundColor Cyan
    Invoke-LoginSpeedDiagnostic
    Start-Sleep -Seconds 2
}

# Count all files
$allReports = Get-ChildItem -Filter "LoginSpeedReport_*.txt" | Where-Object { $_.Name -notlike "*_latest*" }
$allJson = Get-ChildItem -Filter "LoginSpeedReport_*_errors.json" | Where-Object { $_.Name -notlike "*_latest*" }

Write-Host "`n=== Final Verification ===" -ForegroundColor Cyan
Write-Host "Total TXT reports: $($allReports.Count)" -ForegroundColor $(if ($allReports.Count -eq 3) { "Green" } else { "Red" })
Write-Host "Total JSON reports: $($allJson.Count)" -ForegroundColor $(if ($allJson.Count -eq 3) { "Green" } else { "Red" })

Write-Host "`nAll report files:" -ForegroundColor Yellow
$allReports | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host "  - $($_.Name) | Created: $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}
```

**Expected Results:**
- ✅ 3 separate timestamped .txt files exist
- ✅ 3 separate timestamped _errors.json files exist
- ✅ Each file has a unique timestamp in the filename
- ✅ No files are overwritten
- ✅ _latest files are updated with content from the most recent run

---

## Quick Verification Script

Run this comprehensive test to verify all scenarios at once:

```powershell
# Save this as Verify-TimestampedReports.ps1

param(
    [switch]$ModuleTest,
    [switch]$ScriptTest,
    [switch]$CleanupAfter
)

function Test-Module {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Testing LoginSpeedDiagnostic.psm1" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Clean start
    Remove-Item -Path .\LoginSpeedReport*.* -ErrorAction SilentlyContinue
    
    # Two runs
    Import-Module .\LoginSpeedDiagnostic.psm1 -Force
    Write-Host "`n--- Run 1 ---" -ForegroundColor Yellow
    Invoke-LoginSpeedDiagnostic
    Start-Sleep -Seconds 2
    
    Write-Host "`n--- Run 2 ---" -ForegroundColor Yellow
    Invoke-LoginSpeedDiagnostic
    
    # Verify
    $reports = Get-ChildItem -Filter "LoginSpeedReport_*.txt" | Where-Object { $_.Name -notlike "*_latest*" }
    $latest = Get-ChildItem -Filter "LoginSpeedReport_latest.txt" -ErrorAction SilentlyContinue
    $json = Get-ChildItem -Filter "LoginSpeedReport_*_errors.json" | Where-Object { $_.Name -notlike "*_latest*" }
    $latestJson = Get-ChildItem -Filter "LoginSpeedReport_latest_errors.json" -ErrorAction SilentlyContinue
    
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "✓ Timestamped TXT reports: $($reports.Count)/2" -ForegroundColor $(if ($reports.Count -eq 2) { "Green" } else { "Red" })
    Write-Host "✓ Latest TXT exists: $($latest -ne $null)" -ForegroundColor $(if ($latest) { "Green" } else { "Red" })
    Write-Host "✓ Timestamped JSON reports: $($json.Count)/2" -ForegroundColor $(if ($json.Count -eq 2) { "Green" } else { "Red" })
    Write-Host "✓ Latest JSON exists: $($latestJson -ne $null)" -ForegroundColor $(if ($latestJson) { "Green" } else { "Red" })
}

function Test-Script {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Testing LoginSpeedDiagnostic.ps1" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Clean start
    Remove-Item -Path .\LoginSpeedReport*.* -ErrorAction SilentlyContinue
    
    # Two runs
    Write-Host "`n--- Run 1 ---" -ForegroundColor Yellow
    .\LoginSpeedDiagnostic.ps1
    Start-Sleep -Seconds 2
    
    Write-Host "`n--- Run 2 ---" -ForegroundColor Yellow
    .\LoginSpeedDiagnostic.ps1
    
    # Verify
    $reports = Get-ChildItem -Filter "LoginSpeedReport_*.txt" | Where-Object { $_.Name -notlike "*_latest*" }
    $html = Get-ChildItem -Filter "LoginSpeedReport_*.html" | Where-Object { $_.Name -notlike "*_latest*" }
    $json = Get-ChildItem -Filter "LoginSpeedReport_*_errors.json" | Where-Object { $_.Name -notlike "*_latest*" }
    
    $latestTxt = Get-ChildItem -Filter "LoginSpeedReport_latest.txt" -ErrorAction SilentlyContinue
    $latestHtml = Get-ChildItem -Filter "LoginSpeedReport_latest.html" -ErrorAction SilentlyContinue
    $latestJson = Get-ChildItem -Filter "LoginSpeedReport_latest_errors.json" -ErrorAction SilentlyContinue
    
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "✓ Timestamped TXT reports: $($reports.Count)/2" -ForegroundColor $(if ($reports.Count -eq 2) { "Green" } else { "Red" })
    Write-Host "✓ Timestamped HTML reports: $($html.Count)/2" -ForegroundColor $(if ($html.Count -eq 2) { "Green" } else { "Red" })
    Write-Host "✓ Timestamped JSON reports: $($json.Count)/2" -ForegroundColor $(if ($json.Count -eq 2) { "Green" } else { "Red" })
    Write-Host "✓ Latest TXT exists: $($latestTxt -ne $null)" -ForegroundColor $(if ($latestTxt) { "Green" } else { "Red" })
    Write-Host "✓ Latest HTML exists: $($latestHtml -ne $null)" -ForegroundColor $(if ($latestHtml) { "Green" } else { "Red" })
    Write-Host "✓ Latest JSON exists: $($latestJson -ne $null)" -ForegroundColor $(if ($latestJson) { "Green" } else { "Red" })
}

# Run tests
if ($ModuleTest -or (-not $ScriptTest -and -not $ModuleTest)) {
    Test-Module
}

if ($ScriptTest -or (-not $ScriptTest -and -not $ModuleTest)) {
    Test-Script
}

if ($CleanupAfter) {
    Write-Host "`n--- Cleaning up test files ---" -ForegroundColor Yellow
    Remove-Item -Path .\LoginSpeedReport*.* -Confirm:$false
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Verification Complete!" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
```

## Usage

```powershell
# Test both module and script
.\Verify-TimestampedReports.ps1

# Test only module
.\Verify-TimestampedReports.ps1 -ModuleTest

# Test only script
.\Verify-TimestampedReports.ps1 -ScriptTest

# Test and cleanup
.\Verify-TimestampedReports.ps1 -CleanupAfter
```

## Acceptance Criteria Checklist

After running all tests, verify:

- [ ] Reports saved with timestamp format: LoginSpeedReport_YYYYMMDD_HHmmss.txt
- [ ] JSON error logs similarly timestamped: LoginSpeedReport_YYYYMMDD_HHmmss_errors.json
- [ ] HTML reports similarly timestamped (in .ps1): LoginSpeedReport_YYYYMMDD_HHmmss.html
- [ ] LoginSpeedReport_latest.txt copy maintained
- [ ] LoginSpeedReport_latest_errors.json copy maintained
- [ ] LoginSpeedReport_latest.html copy maintained (.ps1 only)
- [ ] Previous reports never overwritten
- [ ] -OutputPath parameter works with directories
- [ ] -OutputPath parameter works with custom file paths
- [ ] Multiple runs create unique timestamped files
- [ ] _latest copies are updated on each run with most recent content
