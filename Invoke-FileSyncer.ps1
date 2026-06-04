#Requires -Version 5.1
<#
.SYNOPSIS
    Monitors source folders for files and copies or moves them to configured destinations.

.DESCRIPTION
    Reads a JSON config file defining watch rules. Each rule specifies a source folder,
    file pattern, one or more destinations, optional rename rules, and whether to copy
    or move the file. A state file tracks already-processed files so unchanged files
    are not re-copied on subsequent runs.

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to config.json in the script directory.

.EXAMPLE
    .\Invoke-FileSyncer.ps1

.EXAMPLE
    .\Invoke-FileSyncer.ps1 -ConfigPath "D:\configs\myconfig.json"

.EXAMPLE
    .\Invoke-FileSyncer.ps1 -WhatIf

.NOTES
    Version: 1.0.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script-scope vars populated from config
$script:LogPath  = $null
$script:LogLevel = 'Info'

#region Helpers

function Get-ConfigProperty {
    # Safe property access for PSCustomObject — avoids StrictMode PropertyNotFoundException
    # when a config key is optional and may not be present in the JSON.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [psobject]$Config,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Name,
        [Parameter()]          [object]$Default = $null
    )
    if ($Config.PSObject.Properties[$Name]) { return $Config.PSObject.Properties[$Name].Value }
    return $Default
}

#endregion

#region Logging

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warn', 'Error', 'Debug')]
        [string]$Level = 'Info'
    )

    if ($Level -eq 'Debug' -and $script:LogLevel -ne 'Debug') { return }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp] [$($Level.PadRight(5))] $Message"

    switch ($Level) {
        'Error' { Write-Host $entry -ForegroundColor Red    }
        'Warn'  { Write-Host $entry -ForegroundColor Yellow }
        'Debug' { Write-Host $entry -ForegroundColor Gray   }
        default { Write-Host $entry }
    }

    if (-not $script:LogPath) { return }

    try {
        $logDir = Split-Path -Path $script:LogPath
        if ($logDir -and -not (Test-Path -Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    } catch {
        Write-Host "[WARN] Could not write to log file '$($script:LogPath)': $_" -ForegroundColor Yellow
    }
}

function Invoke-LogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxSizeMB
    )

    if (-not (Test-Path -Path $LogPath)) { return }

    $logFile = Get-Item -Path $LogPath
    if ($logFile.Length -gt ($MaxSizeMB * 1MB)) {
        $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
        $rotated = [System.IO.Path]::ChangeExtension($LogPath, $null).TrimEnd('.') + "_$stamp.log"
        Rename-Item -Path $LogPath -NewName (Split-Path -Path $rotated -Leaf) -Force
        Write-Log "Log rotated to: $rotated"
    }
}

#endregion

#region State Management

function Get-State {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StatePath
    )

    $state = @{}
    if (-not (Test-Path -Path $StatePath)) { return $state }

    try {
        $json = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # ConvertFrom-Json returns PSCustomObject in PS 5.1 — enumerate properties manually
        foreach ($prop in $json.PSObject.Properties) {
            $state[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Log "Could not read state file '$StatePath', starting fresh: $_" -Level Warn
    }

    return $state
}

function Save-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StatePath
    )

    $stateDir = Split-Path -Path $StatePath
    if ($stateDir -and -not (Test-Path -Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 3 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-FileFingerprint {
    # Returns last-write ticks + file size — detects any change without hashing
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.IO.FileInfo]$File
    )
    return "$($File.LastWriteTimeUtc.Ticks):$($File.Length)"
}

#endregion

#region File Naming

function Resolve-FileName {
    <#
    .SYNOPSIS
        Applies a rename rule to a source filename and returns the resolved name.

    .NOTES
        Rename rule properties (all optional):
            newName           - Replaces the base name entirely (extension preserved)
            prefix            - Prepended to the base name
            suffix            - Appended to the base name, before the extension
            addTimestamp      - Boolean; adds a timestamp to the name
            timestampFormat   - .NET date format string (default: yyyyMMdd_HHmmss)
            timestampPosition - "prefix" or "suffix" (default: "suffix")
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OriginalName,

        [Parameter()]
        [object]$RenameRule
    )

    if ($null -eq $RenameRule) { return $OriginalName }

    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($OriginalName)
    $extension = [System.IO.Path]::GetExtension($OriginalName)

    if ($RenameRule.newName) { $baseName = $RenameRule.newName }

    $position = if ($RenameRule.timestampPosition) { $RenameRule.timestampPosition } else { 'suffix' }
    $format   = if ($RenameRule.timestampFormat)   { $RenameRule.timestampFormat }   else { 'yyyyMMdd_HHmmss' }
    $stamp    = ''

    if ($RenameRule.addTimestamp) { $stamp = Get-Date -Format $format }

    $result = ''
    if ($stamp -and $position -eq 'prefix') { $result += "${stamp}_" }
    if ($RenameRule.prefix) { $result += $RenameRule.prefix }
    $result += $baseName
    if ($RenameRule.suffix) { $result += $RenameRule.suffix }
    if ($stamp -and $position -eq 'suffix') { $result += "_$stamp" }
    $result += $extension

    return $result
}

#endregion

#region Rule Processing

function Invoke-Rule {
    # SupportsShouldProcess required so $PSCmdlet.ShouldProcess() is valid in this scope
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if (-not $Rule.enabled) {
        Write-Log "  Rule '$($Rule.name)' is disabled — skipping." -Level Debug
        return
    }

    Write-Log "--- Rule: $($Rule.name) ---"

    if (-not (Test-Path -Path $Rule.sourceFolder)) {
        Write-Log "  Source folder not found: $($Rule.sourceFolder)" -Level Warn
        return
    }

    $files = @(Get-ChildItem -Path $Rule.sourceFolder -Filter $Rule.filePattern -File -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0) {
        Write-Log "  No files match '$($Rule.filePattern)' in $($Rule.sourceFolder)"
        return
    }

    Write-Log "  Found $($files.Count) file(s) matching '$($Rule.filePattern)'"

    foreach ($file in $files) {
        $stateKey    = "$($Rule.name)|$($file.FullName)"
        $fingerprint = Get-FileFingerprint -File $file

        if ($Rule.onlyNew -and $State.ContainsKey($stateKey) -and $State[$stateKey] -eq $fingerprint) {
            Write-Log "  Skipping (already processed): $($file.Name)" -Level Debug
            continue
        }

        Write-Log "  Processing: $($file.Name)"
        $allSucceeded = $true

        foreach ($dest in $Rule.destinations) {
            try {
                if (-not (Test-Path -Path $dest.path)) {
                    if ($PSCmdlet.ShouldProcess($dest.path, 'Create destination directory')) {
                        New-Item -ItemType Directory -Path $dest.path -Force | Out-Null
                    }
                    Write-Log "    Created directory: $($dest.path)"
                }

                $destName = Resolve-FileName -OriginalName $file.Name -RenameRule $dest.rename
                $destPath = Join-Path -Path $dest.path -ChildPath $destName

                if ($PSCmdlet.ShouldProcess($destPath, "Copy '$($file.Name)'")) {
                    Copy-Item -Path $file.FullName -Destination $destPath -Force
                }
                Write-Log "    -> $destPath"

            } catch {
                Write-Log "    FAILED to copy to '$($dest.path)': $_" -Level Error
                $allSucceeded = $false
            }
        }

        # Delete source only after all destinations succeeded
        if ($allSucceeded -and $Rule.action -eq 'move') {
            try {
                if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete source (move)')) {
                    Remove-Item -Path $file.FullName -Force
                }
                Write-Log "    Source deleted (move): $($file.FullName)"
            } catch {
                Write-Log "    FAILED to delete source file: $_" -Level Error
                $allSucceeded = $false
            }
        }

        if ($allSucceeded) {
            $State[$stateKey] = $fingerprint
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -Path $ConfigPath)) {
    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.IO.FileNotFoundException]::new("Config file not found: $ConfigPath"),
            'ConfigNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $ConfigPath
        )
    )
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.FormatException]::new(
                "Failed to parse '$ConfigPath': $_`n" +
                "In JSON, every backslash in a path must be doubled.`n" +
                "  Local path:  C:\Logs\File  ->  `"C:\\Logs\\File`"`n" +
                "  UNC path:    \\server\share  ->  `"\\\\server\\share`""
            ),
            'ConfigParseError',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $ConfigPath
        )
    )
}

$script:LogPath  = Get-ConfigProperty -Config $config -Name 'logPath'
$script:LogLevel = Get-ConfigProperty -Config $config -Name 'logLevel'  -Default 'Info'
$maxLogSizeMB    = [int](Get-ConfigProperty -Config $config -Name 'maxLogSizeMB' -Default 10)
$statePath       = Get-ConfigProperty -Config $config -Name 'statePath' -Default (Join-Path $PSScriptRoot 'state.json')

if ($script:LogPath) { Invoke-LogRotation -LogPath $script:LogPath -MaxSizeMB $maxLogSizeMB }

Write-Log ('=' * 60)
Write-Log "FileSyncer started | Config: $ConfigPath"

$state = Get-State -StatePath $statePath
$rules = @($config.watchRules)
Write-Log "Loaded $($rules.Count) rule(s)"

foreach ($rule in $rules) {
    try {
        Invoke-Rule -Rule $rule -State $state
    } catch {
        Write-Log "Unhandled error in rule '$($rule.name)': $_" -Level Error
    }
}

Save-State -State $state -StatePath $statePath
Write-Log "FileSyncer complete"
Write-Log ('=' * 60)
