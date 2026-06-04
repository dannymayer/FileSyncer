# FileSyncer

Monitors source folders for files and copies or moves them to one or more destinations. Rules, rename patterns, and destinations are all driven by a JSON config file. Designed to run as a Windows Scheduled Task.

## Files

| File | Purpose |
|---|---|
| `Invoke-FileSyncer.ps1` | Main script — evaluates rules and copies/moves files |
| `Register-FileSyncerTask.ps1` | One-time setup — creates the Windows Scheduled Task |
| `config.json` | Configuration — rules, destinations, rename patterns, logging |

---

## Quick Start

1. Edit `config.json` with your source folders, file patterns, and destinations.
2. Open an **elevated** PowerShell prompt.
3. Register the scheduled task:
   ```powershell
   .\Register-FileSyncerTask.ps1
   ```
4. Test a run immediately:
   ```powershell
   Start-ScheduledTask -TaskName 'FileSyncer' -TaskPath '\FileSyncer\'
   ```

---

## Configuration

All behavior is controlled by `config.json`. A different config file can be passed via `-ConfigPath`.

### Top-Level Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `logPath` | string | *(none)* | Path to the log file. Directory is created automatically. Omit to log to console only. |
| `statePath` | string | `state.json` next to script | Tracks processed files so unchanged files are not re-copied on subsequent runs. |
| `logLevel` | string | `Info` | `Info` or `Debug`. Debug logs skipped files and disabled rules. |
| `maxLogSizeMB` | int | `10` | Log file is rotated (renamed with a timestamp) when it exceeds this size. |
| `watchRules` | array | — | One or more rule objects (see below). |

### Rule Properties

| Property | Type | Required | Description |
|---|---|---|---|
| `name` | string | Yes | Unique display name used in logs and to key the state file. |
| `enabled` | bool | Yes | Set to `false` to skip a rule without removing it. |
| `sourceFolder` | string | Yes | Folder to watch. UNC paths are supported. |
| `filePattern` | string | Yes | Wildcard filter applied to the source folder (e.g. `*.csv`, `Report_*.xlsx`). |
| `action` | string | Yes | `"copy"` — leave source intact. `"move"` — delete source after all destinations succeed. |
| `onlyNew` | bool | Yes | `true` — skip files whose name, size, and last-write time match a previous run. `false` — always copy. |
| `destinations` | array | Yes | One or more destination objects (see below). |

### Destination Properties

| Property | Type | Required | Description |
|---|---|---|---|
| `path` | string | Yes | Target directory. Created automatically if it does not exist. UNC paths are supported. |
| `rename` | object or null | Yes | Rename rule to apply (see below). Use `null` to keep the original filename. |

### Rename Rule Properties

All properties are optional and combinable.

| Property | Type | Description |
|---|---|---|
| `newName` | string | Replaces the base filename entirely. The original extension is preserved. |
| `prefix` | string | Prepended to the base name. |
| `suffix` | string | Appended to the base name, before the extension. |
| `addTimestamp` | bool | Adds a datestamp to the filename. |
| `timestampFormat` | string | .NET date format string. Default: `yyyyMMdd_HHmmss`. |
| `timestampPosition` | string | `"prefix"` or `"suffix"`. Default: `"suffix"`. |

**Filename assembly order:** `[timestamp_]` `[prefix]` `baseName` `[suffix]` `[_timestamp]` `.ext`

#### Rename Examples

| Rule | Input | Output |
|---|---|---|
| `"rename": null` | `Report.xlsx` | `Report.xlsx` |
| `prefix: "DONE_"` | `Report.xlsx` | `DONE_Report.xlsx` |
| `suffix: "_archived"` | `Report.xlsx` | `Report_archived.xlsx` |
| `addTimestamp: true, timestampFormat: "yyyyMMdd", timestampPosition: "suffix"` | `Report.xlsx` | `Report_20260604.xlsx` |
| `prefix: "DONE_", addTimestamp: true, timestampPosition: "suffix"` | `Report.xlsx` | `DONE_Report_20260604_143022.xlsx` |
| `newName: "output", addTimestamp: true` | `anything.csv` | `output_20260604_143022.csv` |

### Example Config

```json
{
  "logPath": "C:\\Logs\\FileSyncer\\FileSyncer.log",
  "statePath": "C:\\Logs\\FileSyncer\\state.json",
  "logLevel": "Info",
  "maxLogSizeMB": 10,
  "watchRules": [
    {
      "name": "Daily Sales Report",
      "enabled": true,
      "sourceFolder": "C:\\Reports\\Incoming",
      "filePattern": "SalesReport_*.xlsx",
      "action": "copy",
      "onlyNew": true,
      "destinations": [
        {
          "path": "C:\\Reports\\Archive",
          "rename": {
            "addTimestamp": true,
            "timestampFormat": "yyyyMMdd",
            "timestampPosition": "suffix"
          }
        },
        {
          "path": "\\\\fileserver\\Shared\\Reports",
          "rename": null
        }
      ]
    }
  ]
}
```

---

## Running the Script

### Manually

```powershell
# Normal run using default config.json
.\Invoke-FileSyncer.ps1

# Point to a different config file
.\Invoke-FileSyncer.ps1 -ConfigPath "D:\configs\prod.json"

# Dry run — shows what would be copied/moved without touching any files
.\Invoke-FileSyncer.ps1 -WhatIf
```

### As a Scheduled Task

`Register-FileSyncerTask.ps1` must be run from an **elevated** prompt. It creates the task under `\FileSyncer\` in Task Scheduler.

```powershell
# Default: SYSTEM account, runs hourly
.\Register-FileSyncerTask.ps1

# Named service account, every 30 minutes
.\Register-FileSyncerTask.ps1 -RunAsUser "DOMAIN\svc_filesyncer" -IntervalMinutes 30

# Preview the registration without making changes
.\Register-FileSyncerTask.ps1 -WhatIf

# Overwrite an existing task with the same name
.\Register-FileSyncerTask.ps1 -Force
```

**Parameters for `Register-FileSyncerTask.ps1`:**

| Parameter | Default | Description |
|---|---|---|
| `-ScriptPath` | `Invoke-FileSyncer.ps1` next to this file | Full path to the main script. |
| `-ConfigPath` | `config.json` next to this file | Full path to the config file. |
| `-TaskName` | `FileSyncer` | Scheduled Task name. |
| `-TaskFolder` | `\FileSyncer\` | Folder path in Task Scheduler. |
| `-RunAsUser` | `SYSTEM` | Account to run the task as. |
| `-IntervalMinutes` | `60` | Run frequency in minutes (1–1440). |
| `-Force` | — | Replace an existing task without prompting. |

The task is configured to:

- Start at the next top-of-hour after registration
- Repeat indefinitely on the configured interval
- Skip new instances if a previous run is still active (`IgnoreNew`)
- Retry up to 3 times with a 5-minute delay on failure
- Run whether or not a user is logged in

---

## State File

When `onlyNew: true`, the script records a fingerprint (last-write time + file size) for each successfully processed file in `state.json`. On subsequent runs, files whose fingerprint matches are skipped.

To force a file to be re-processed, either:

- Delete the relevant entry from `state.json`, or
- Delete `state.json` entirely to reset all rules, or
- Set `"onlyNew": false` in the rule temporarily.

---

## Logging

Each run appends to the file specified by `logPath`. Log entries include a timestamp and level:

```
[2026-06-04 14:30:01] [INFO ] ============================================================
[2026-06-04 14:30:01] [INFO ] FileSyncer started | Config: C:\Scripts\FileSyncer\config.json
[2026-06-04 14:30:01] [INFO ] Loaded 1 rule(s)
[2026-06-04 14:30:01] [INFO ] --- Rule: Daily Sales Report ---
[2026-06-04 14:30:01] [INFO ]   Found 2 file(s) matching 'SalesReport_*.xlsx'
[2026-06-04 14:30:01] [INFO ]   Processing: SalesReport_20260604.xlsx
[2026-06-04 14:30:01] [INFO ]     -> C:\Reports\Archive\SalesReport_20260604_20260604.xlsx
[2026-06-04 14:30:02] [INFO ]     -> \\fileserver\Shared\Reports\SalesReport_20260604.xlsx
[2026-06-04 14:30:02] [INFO ] FileSyncer complete
```

When the log file exceeds `maxLogSizeMB`, it is renamed with a timestamp (e.g. `FileSyncer_20260604_143001.log`) and a new log file is started.

---

## Requirements

- Windows PowerShell 5.1 or later
- Write access to all destination folders
- Network access if using UNC paths
- Administrator rights to register the scheduled task (setup only)
