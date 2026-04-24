@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'LoginSpeedDiagnostic.psm1'

    # Version number of this module.
    ModuleVersion = '1.0.0'

    # ID used to uniquely identify this module
    GUID = 'a1b2c3d4-e5f6-4789-a0b1-c2d3e4f5a6b7'

    # Author of this module
    Author = 'GauntNight'

    # Company or vendor of this module
    CompanyName = ''

    # Copyright statement for this module
    Copyright = '(c) 2026. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Measures and diagnoses slow login times on enterprise devices joined to an Active Directory domain. Identifies root causes including local device performance, network connectivity, GPO processing, roaming profiles, logon scripts, and DNS/DC discovery delays.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = @('Invoke-LoginSpeedDiagnostic')

    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries.
            Tags = @('ActiveDirectory', 'Diagnostics', 'Performance', 'Login', 'GPO', 'Troubleshooting')

            # A URL to the license for this module.
            # LicenseUri = ''

            # A URL to the main website for this project.
            # ProjectUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = 'Initial release - PowerShell module packaging of the AD Login Speed Diagnostic tool.'
        }
    }
}
