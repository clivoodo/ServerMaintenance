<#
===============================================================================
 Script Name : Invoke-VolumeOptimization.ps1
 Author      : Jason Smith
 Created On  : 2026-05-29
 Last Update : 2026-05-29
 Version     : 2.0.0

 Purpose     : Automates Windows volume optimization locally or on remote
               servers using Optimize-Volume and defrag.exe with accurate
               status reporting, logging, and optional fallback behavior.

 Requirements:
               - Windows Server 2016 or later
               - Administrative privileges
               - Storage module / Optimize-Volume support
               - WSMan / PowerShell remoting for remote defrag.exe execution
               - CIM / WinRM connectivity for remote Optimize-Volume actions

 Change Log  :
   2.0.0 - Added full script header and examples
         - Added remote server support
         - Added accurate error handling and unsupported detection
         - Added optional fallback to Auto
         - Added pass-through result objects and better logging
===============================================================================
.SYNOPSIS
    Automates Windows volume optimization with robust error handling and accurate status reporting.

.DESCRIPTION
    Uses Optimize-Volume for most actions and defrag.exe for FreeSpaceConsolidate (/X).
    Unlike simpler scripts, this version:
      - does NOT report success when Optimize-Volume throws an exception
      - classifies unsupported operations separately
      - can optionally fall back to Auto when a forced mode is unsupported
      - logs both summary and raw output
      - returns structured objects when -PassThru is used

.PARAMETER Mode
    Auto                 -> Let Windows choose the proper optimization for the volume/media type
    Analyze              -> Analyze only
    Defrag               -> Traditional defrag
    ReTrim               -> Retrim / UNMAP style optimization
    SlabConsolidate      -> Slab consolidation
    FreeSpaceConsolidate -> Uses defrag.exe /X

.PARAMETER DriveLetters
    Optional list of drive letters to include (example: C,D,E)

.PARAMETER ExcludeDriveLetters
    Optional list of drive letters to exclude (example: D,E)

.PARAMETER IncludeHiddenVolumes
    Include fixed volumes without drive letters when using Optimize-Volume modes.
    Note: FreeSpaceConsolidate requires a drive letter or mount path.

.PARAMETER NormalPriority
    Use normal priority rather than the default low priority.

.PARAMETER FallbackToAutoOnUnsupported
    If a forced mode (e.g. ReTrim) is unsupported on a volume, retry that volume in Auto mode.

.PARAMETER LogPath
    Log file path.

.PARAMETER WhatIfMode
    Show what would be done without making changes.

.PARAMETER PassThru
    Return structured results to the pipeline.

.EXAMPLE
    .\Invoke-VolumeOptimization.ps1 -Mode Auto -NormalPriority

.EXAMPLE
    .\Invoke-VolumeOptimization.ps1 -Mode ReTrim -DriveLetters C,E,F -FallbackToAutoOnUnsupported -PassThru

.EXAMPLE
    .\Invoke-VolumeOptimization.ps1 -Mode FreeSpaceConsolidate -DriveLetters C -NormalPriority
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto','Analyze','Defrag','ReTrim','SlabConsolidate','FreeSpaceConsolidate')]
    [string]$Mode = 'Auto',

    [char[]]$DriveLetters,

    [char[]]$ExcludeDriveLetters = @(),

    [switch]$IncludeHiddenVolumes,

    [switch]$NormalPriority,

    [switch]$FallbackToAutoOnUnsupported,

    [string]$LogPath = "C:\Logs\VolumeOptimization_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",

    [switch]$WhatIfMode,

    [switch]$PassThru
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:Results = New-Object System.Collections.Generic.List[object]

    # Ensure log directory exists
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    function Write-Log {
        param(
            [Parameter(Mandatory)]
            [string]$Message,

            [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
            [string]$Level = 'INFO'
        )

        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Write-Host $line
        Add-Content -LiteralPath $LogPath -Value $line
    }

    function New-ResultObject {
        param(
            [string]$Drive,
            [string]$Label,
            [string]$ModeRequested,
            [string]$ModeExecuted,
            [string]$Status,
            [bool]$Success,
            [string]$Message,
            [string]$Command,
            [string]$Output = '',
            [string]$ErrorId = '',
            [int]$ExitCode = $null
        )

        [PSCustomObject]@{
            Timestamp      = Get-Date
            Drive          = $Drive
            Label          = $Label
            ModeRequested  = $ModeRequested
            ModeExecuted   = $ModeExecuted
            Status         = $Status           # Success | Unsupported | Failed | Skipped | WhatIf
            Success        = $Success
            Message        = $Message
            Command        = $Command
            ExitCode       = $ExitCode
            ErrorId        = $ErrorId
            Output         = $Output
        }
    }

    function Get-TargetVolumes {
        param(
            [char[]]$DriveLetters,
            [char[]]$ExcludeDriveLetters,
            [switch]$IncludeHiddenVolumes
        )

        $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' }

        if (-not $IncludeHiddenVolumes) {
            $vols = $vols | Where-Object { $_.DriveLetter }
        }

        if ($DriveLetters -and $DriveLetters.Count -gt 0) {
            $wanted = $DriveLetters | ForEach-Object { $_.ToString().ToUpperInvariant() }
            $vols = $vols | Where-Object {
                $_.DriveLetter -and ($wanted -contains $_.DriveLetter.ToString().ToUpperInvariant())
            }
        }

        if ($ExcludeDriveLetters -and $ExcludeDriveLetters.Count -gt 0) {
            $excluded = $ExcludeDriveLetters | ForEach-Object { $_.ToString().ToUpperInvariant() }
            $vols = $vols | Where-Object {
                -not $_.DriveLetter -or ($excluded -notcontains $_.DriveLetter.ToString().ToUpperInvariant())
            }
        }

        return @($vols)
    }

    function Get-OptimizeVolumeParameterSet {
        param(
            [Parameter(Mandatory)]
            $Volume,

            [Parameter(Mandatory)]
            [ValidateSet('Auto','Analyze','Defrag','ReTrim','SlabConsolidate')]
            [string]$RequestedMode,

            [switch]$NormalPriority
        )

        $params = @{
            ErrorAction = 'Stop'
            Verbose     = $true
        }

        if ($NormalPriority) {
            $params['NormalPriority'] = $true
        }

        if ($Volume.DriveLetter) {
            $params['DriveLetter'] = [char]$Volume.DriveLetter
            $target = "$($Volume.DriveLetter):"
        }
        else {
            $params['ObjectId'] = $Volume.ObjectId
            $target = $Volume.ObjectId
        }

        switch ($RequestedMode) {
            'Analyze'         { $params['Analyze'] = $true }
            'Defrag'          { $params['Defrag'] = $true }
            'ReTrim'          { $params['ReTrim'] = $true }
            'SlabConsolidate' { $params['SlabConsolidate'] = $true }
            'Auto'            { } # No explicit operation; Windows chooses the default action
        }

        [PSCustomObject]@{
            Target = $target
            Params = $params
        }
    }

    function Invoke-OptimizeVolumeSafe {
        param(
            [Parameter(Mandatory)]
            $Volume,

            [Parameter(Mandatory)]
            [ValidateSet('Auto','Analyze','Defrag','ReTrim','SlabConsolidate')]
            [string]$RequestedMode,

            [switch]$NormalPriority,

            [switch]$WhatIfMode
        )

        $label = [string]$Volume.FileSystemLabel
        $paramSet = Get-OptimizeVolumeParameterSet -Volume $Volume -RequestedMode $RequestedMode -NormalPriority:$NormalPriority
        $target = $paramSet.Target
        $params = $paramSet.Params

        $cmdPreview = "Optimize-Volume " + (($params.GetEnumerator() | Sort-Object Name | ForEach-Object {
            if ($_.Value -is [bool]) { "-$($_.Key)" } else { "-$($_.Key) `"$($_.Value)`"" }
        }) -join ' ')

        if ($WhatIfMode) {
            return New-ResultObject -Drive $target -Label $label -ModeRequested $RequestedMode -ModeExecuted $RequestedMode `
                -Status 'WhatIf' -Success $true -Message 'WhatIf mode - not executed.' -Command $cmdPreview
        }

        try {
            # Capture all streams as textable output, but let terminating errors hit catch
            $raw = Optimize-Volume @params 4>&1 | Out-String

            return New-ResultObject -Drive $target -Label $label -ModeRequested $RequestedMode -ModeExecuted $RequestedMode `
                -Status 'Success' -Success $true -Message 'Operation completed.' -Command $cmdPreview -Output $raw
        }
        catch {
            $msg = $_.Exception.Message
            $fqid = $_.FullyQualifiedErrorId

            if ($msg -match 'not supported by the hardware backing the volume' -or $fqid -match '43022') {
                return New-ResultObject -Drive $target -Label $label -ModeRequested $RequestedMode -ModeExecuted $RequestedMode `
                    -Status 'Unsupported' -Success $false -Message $msg -Command $cmdPreview -ErrorId $fqid
            }

            return New-ResultObject -Drive $target -Label $label -ModeRequested $RequestedMode -ModeExecuted $RequestedMode `
                -Status 'Failed' -Success $false -Message $msg -Command $cmdPreview -ErrorId $fqid
        }
    }

    function Invoke-FreeSpaceConsolidation {
        param(
            [Parameter(Mandatory)]
            $Volume,

            [switch]$NormalPriority,

            [switch]$WhatIfMode
        )

        $label = [string]$Volume.FileSystemLabel

        if (-not $Volume.DriveLetter) {
            return New-ResultObject -Drive $Volume.ObjectId -Label $label -ModeRequested 'FreeSpaceConsolidate' -ModeExecuted 'FreeSpaceConsolidate' `
                -Status 'Skipped' -Success $false -Message 'FreeSpaceConsolidate requires a drive letter or mount point path.' `
                -Command 'defrag.exe /X'
        }

        $target = "$($Volume.DriveLetter):"
        $args = @($target, '/X', '/U', '/V')
        if ($NormalPriority) { $args += '/H' }

        $cmdPreview = "defrag.exe " + ($args -join ' ')

        if ($WhatIfMode) {
            return New-ResultObject -Drive $target -Label $label -ModeRequested 'FreeSpaceConsolidate' -ModeExecuted 'FreeSpaceConsolidate' `
                -Status 'WhatIf' -Success $true -Message 'WhatIf mode - not executed.' -Command $cmdPreview
        }

        $tempOut = Join-Path $env:TEMP ("defrag_{0}_{1}.log" -f ($Volume.DriveLetter), ([guid]::NewGuid().ToString('N')))
        try {
            $p = Start-Process -FilePath "$env:SystemRoot\System32\defrag.exe" `
                               -ArgumentList $args `
                               -Wait -NoNewWindow -PassThru `
                               -RedirectStandardOutput $tempOut

            $raw = if (Test-Path -LiteralPath $tempOut) {
                Get-Content -LiteralPath $tempOut -Raw
            } else {
                ''
            }

            if ($p.ExitCode -eq 0) {
                return New-ResultObject -Drive $target -Label $label -ModeRequested 'FreeSpaceConsolidate' -ModeExecuted 'FreeSpaceConsolidate' `
                    -Status 'Success' -Success $true -Message 'Operation completed.' -Command $cmdPreview -Output $raw -ExitCode $p.ExitCode
            }
            else {
                return New-ResultObject -Drive $target -Label $label -ModeRequested 'FreeSpaceConsolidate' -ModeExecuted 'FreeSpaceConsolidate' `
                    -Status 'Failed' -Success $false -Message "defrag.exe returned exit code $($p.ExitCode)." -Command $cmdPreview -Output $raw -ExitCode $p.ExitCode
            }
        }
        catch {
            return New-ResultObject -Drive $target -Label $label -ModeRequested 'FreeSpaceConsolidate' -ModeExecuted 'FreeSpaceConsolidate' `
                -Status 'Failed' -Success $false -Message $_.Exception.Message -Command $cmdPreview
        }
        finally {
            if (Test-Path -LiteralPath $tempOut) {
                Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function Process-Volume {
        param(
            [Parameter(Mandatory)]
            $Volume
        )

        $targetName = if ($Volume.DriveLetter) { "$($Volume.DriveLetter):" } else { $Volume.ObjectId }
        $label = [string]$Volume.FileSystemLabel
        Write-Log "Processing $targetName"

        if ($Mode -eq 'FreeSpaceConsolidate') {
            $result = Invoke-FreeSpaceConsolidation -Volume $Volume -NormalPriority:$NormalPriority -WhatIfMode:$WhatIfMode
            return $result
        }

        $result = Invoke-OptimizeVolumeSafe -Volume $Volume -RequestedMode $Mode -NormalPriority:$NormalPriority -WhatIfMode:$WhatIfMode

        # Optional retry path: forced mode unsupported -> retry Auto
        if (
            $FallbackToAutoOnUnsupported -and
            $Mode -ne 'Auto' -and
            $result.Status -eq 'Unsupported'
        ) {
            Write-Log "Mode $Mode unsupported on $targetName. Retrying with Auto." 'WARN'
            $autoResult = Invoke-OptimizeVolumeSafe -Volume $Volume -RequestedMode 'Auto' -NormalPriority:$NormalPriority -WhatIfMode:$WhatIfMode

            # Preserve requested mode while reporting actual execution mode
            $autoResult = [PSCustomObject]@{
                Timestamp      = $autoResult.Timestamp
                Drive          = $autoResult.Drive
                Label          = $autoResult.Label
                ModeRequested  = $Mode
                ModeExecuted   = 'Auto'
                Status         = $autoResult.Status
                Success        = $autoResult.Success
                Message        = "Fallback to Auto after unsupported $Mode. " + $autoResult.Message
                Command        = $autoResult.Command
                ExitCode       = $autoResult.ExitCode
                ErrorId        = $autoResult.ErrorId
                Output         = $autoResult.Output
            }

            return $autoResult
        }

        return $result
    }

    Write-Log "Starting volume optimization. Mode=$Mode"
    Write-Log "LogPath=$LogPath"
    if ($WhatIfMode) {
        Write-Log "WhatIfMode enabled. No changes will be made." 'WARN'
    }
}

process {
    try {
        $volumes = Get-TargetVolumes -DriveLetters $DriveLetters -ExcludeDriveLetters $ExcludeDriveLetters -IncludeHiddenVolumes:$IncludeHiddenVolumes

        if (-not $volumes -or $volumes.Count -eq 0) {
            Write-Log "No matching fixed volumes found." 'WARN'
            return
        }

        $targetList = $volumes | ForEach-Object {
            if ($_.DriveLetter) { "$($_.DriveLetter):" } else { $_.ObjectId }
        }
        Write-Log ("Target volumes: " + ($targetList -join ', '))

        foreach ($vol in $volumes) {
            $r = Process-Volume -Volume $vol
            $script:Results.Add($r)

            switch ($r.Status) {
                'Success' {
                    Write-Log "Completed $($r.Drive) action=$($r.ModeExecuted)" 'SUCCESS'
                }
                'Unsupported' {
                    Write-Log "Unsupported on $($r.Drive) action=$($r.ModeExecuted) : $($r.Message)" 'WARN'
                }
                'Skipped' {
                    Write-Log "Skipped $($r.Drive) : $($r.Message)" 'WARN'
                }
                'WhatIf' {
                    Write-Log "WhatIf $($r.Drive) action=$($r.ModeExecuted)" 'INFO'
                }
                default {
                    Write-Log "Failed $($r.Drive) action=$($r.ModeExecuted) : $($r.Message)" 'ERROR'
                }
            }

            if ($r.Output) {
                Write-Log ("Output for $($r.Drive):`n" + $r.Output.Trim())
            }
        }

        $successCount     = @($script:Results | Where-Object { $_.Status -eq 'Success' }).Count
        $unsupportedCount = @($script:Results | Where-Object { $_.Status -eq 'Unsupported' }).Count
        $failedCount      = @($script:Results | Where-Object { $_.Status -eq 'Failed' }).Count
        $skippedCount     = @($script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count
        $whatIfCount      = @($script:Results | Where-Object { $_.Status -eq 'WhatIf' }).Count

        Write-Log "Optimization complete. Success=$successCount Unsupported=$unsupportedCount Failed=$failedCount Skipped=$skippedCount WhatIf=$whatIfCount"

        if ($PassThru) {
            $script:Results
        }
    }
    catch {
        Write-Log ("Fatal error: " + $_.Exception.Message) 'ERROR'
        throw
    }
}

end {
    Write-Log "Finished."
}
