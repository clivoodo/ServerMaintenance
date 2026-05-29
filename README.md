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
