#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers a Windows Scheduled Task to run Invoke-FileSyncer.ps1 on a recurring interval.

.DESCRIPTION
    Creates a task under \FileSyncer\ in Task Scheduler. The task starts at the next top-of-hour
    and repeats indefinitely on the configured interval. Requires elevation (Run as Administrator).

.PARAMETER ScriptPath
    Full path to Invoke-FileSyncer.ps1. Defaults to the script in the same folder as this file.

.PARAMETER ConfigPath
    Full path to config.json. Defaults to config.json in the same folder as this file.

.PARAMETER TaskName
    Name of the scheduled task. Default: FileSyncer

.PARAMETER TaskFolder
    Task Scheduler folder path. Default: \FileSyncer\

.PARAMETER RunAsUser
    Account to run the task under. Use 'SYSTEM' for a service account (no password needed),
    or specify a domain\user for a named account. Default: SYSTEM

.PARAMETER IntervalMinutes
    How often the task runs, in minutes. Accepts 1–1440 (up to once per day). Default: 60 (hourly)

.PARAMETER Force
    Overwrites an existing task with the same name without prompting.

.EXAMPLE
    # Run from an elevated prompt in the script directory:
    .\Register-FileSyncerTask.ps1

.EXAMPLE
    # Use a specific service account and 30-minute interval:
    .\Register-FileSyncerTask.ps1 -RunAsUser "DOMAIN\svc_filesyncer" -IntervalMinutes 30

.EXAMPLE
    # Preview without making changes:
    .\Register-FileSyncerTask.ps1 -WhatIf

.NOTES
    Version: 1.0.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Invoke-FileSyncer.ps1'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'FileSyncer',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskFolder = '\FileSyncer\',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RunAsUser = 'SYSTEM',

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 60,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate file paths with clear messages before any task work begins
foreach ($path in @($ScriptPath, $ConfigPath)) {
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new("Required file not found: $path"),
                'RequiredFileNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $path
            )
        )
    }
}

# Check for existing task
$existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -ErrorAction SilentlyContinue

if ($existingTask -and -not $Force) {
    Write-Warning "Task '$TaskFolder$TaskName' already exists. Run with -Force to replace it."
    return
}

# Build task components
$argument = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

$taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

# Start at the next top-of-hour so the first run is predictable
$now       = Get-Date
$startTime = $now.Date.AddHours($now.Hour + 1)

$taskTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At $startTime `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$taskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances  IgnoreNew `
    -RestartCount       3 `
    -RestartInterval    (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -Hidden

if ($RunAsUser -eq 'SYSTEM') {
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId    'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel  Highest
} else {
    # Named account — S4U logon runs even when the user is not interactively logged in
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId    $RunAsUser `
        -LogonType S4U `
        -RunLevel  Highest
}

$registerParams = @{
    TaskName    = $TaskName
    TaskPath    = $TaskFolder
    Action      = $taskAction
    Trigger     = $taskTrigger
    Settings    = $taskSettings
    Principal   = $taskPrincipal
    Description = "FileSyncer: monitors source folders and copies/moves files to configured destinations. Config: $ConfigPath"
}

# Register (or replace) the task
try {
    if ($existingTask) {
        if ($PSCmdlet.ShouldProcess("$TaskFolder$TaskName", 'Replace existing scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Confirm:$false
            Register-ScheduledTask @registerParams | Out-Null
            Write-Host "Task replaced:   $TaskFolder$TaskName" -ForegroundColor Green
            Write-Host "Script:          $ScriptPath"          -ForegroundColor Cyan
            Write-Host "Config:          $ConfigPath"          -ForegroundColor Cyan
            Write-Host "Runs as:         $RunAsUser"           -ForegroundColor Cyan
            Write-Host "First run:       $startTime"           -ForegroundColor Cyan
            Write-Host "Interval:        every $IntervalMinutes minute(s)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "To test immediately:" -ForegroundColor White
            Write-Host "  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskFolder'" -ForegroundColor White
        }
    } else {
        if ($PSCmdlet.ShouldProcess("$TaskFolder$TaskName", 'Register new scheduled task')) {
            Register-ScheduledTask @registerParams | Out-Null
            Write-Host "Task registered: $TaskFolder$TaskName" -ForegroundColor Green
            Write-Host "Script:          $ScriptPath"          -ForegroundColor Cyan
            Write-Host "Config:          $ConfigPath"          -ForegroundColor Cyan
            Write-Host "Runs as:         $RunAsUser"           -ForegroundColor Cyan
            Write-Host "First run:       $startTime"           -ForegroundColor Cyan
            Write-Host "Interval:        every $IntervalMinutes minute(s)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "To test immediately:" -ForegroundColor White
            Write-Host "  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskFolder'" -ForegroundColor White
        }
    }
} catch {
    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("Failed to register scheduled task '$TaskFolder$TaskName': $_"),
            'TaskRegistrationFailed',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $TaskName
        )
    )
}
