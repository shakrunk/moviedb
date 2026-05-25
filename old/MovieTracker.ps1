<#
.SYNOPSIS
    Local PowerShell management engine for a self-documenting JSON movie log.
.DESCRIPTION
    Provides transactional add and update mutations for a localized JSON file,
    ensuring formatting consistency and strict type safety.
#>

$Global:MovieDbPath = Join-Path $PSScriptRoot "movies.json"

function Initialize-MovieDatabase {
    [CmdletBinding()]
    param (
        [string]$Path = $Global:MovieDbPath
    )
    if (-not (Test-Path $Path)) {
        Throw "Database file not found at $Path. Please ensure the baseline movies.json is present."
    }
}

function Add-MovieEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 5)] [int]$Rating,
        [Parameter(Mandatory = $false)] [string]$ReleaseDate,
        [Parameter(Mandatory = $false)] [string]$Genre,
        [Parameter(Mandatory = $false)] [string]$Director,
        [Parameter(Mandatory = $false)] [string]$Notes = ""
    )
    
    Initialize-MovieDatabase
    
    # Read and parse raw data
    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json
    
    # Check for existing entry to prevent duplicates
    if ($RawJson.log.Title -contains $Title) {
        Write-Warning "Entry for '$Title' already exists. Use Update-MovieEntry instead."
        return
    }
    
    # Construct distinct new record object matching schema types
    $NewRecord = [PSCustomObject]@{
        Title       = $Title
        Rating      = if ($PSBoundParameters.ContainsKey('Rating')) { $Rating } else { $null }
        ReleaseDate = $ReleaseDate
        Genre       = $Genre
        Director    = $Director
        Notes       = $Notes
    }
    
    # Append to the data log collection
    $RawJson.log += $NewRecord
    
    # Export back to file with standardized JSON formatting arrays
    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Successfully appended '$Title' to the data store." -ForegroundColor Green
}

function Update-MovieEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $true)] [ValidateSet('Rating', 'ReleaseDate', 'Genre', 'Director', 'Notes')] [string]$Property,
        [Parameter(Mandatory = $true)] $Value
    )
    
    Initialize-MovieDatabase
    
    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json
    $TargetRecord = $RawJson.log | Where-Object { $_.Title -eq $Title }
    
    if (-not $TargetRecord) {
        Write-Error "Movie '$Title' not found in the data store."
        return
    }
    
    # Enforce strict type conversions for explicit schema values
    if ($Property -eq 'Rating') {
        $TargetRecord.$Property = [int]$Value
    } else {
        $TargetRecord.$Property = [string]$Value
    }
    
    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Successfully updated $Property for '$Title'." -ForegroundColor Green
}

function Copy-MovieDbToClipboard {
    [CmdletBinding()]
    param()
    Initialize-MovieDatabase
    Get-Content -Raw -Path $Global:MovieDbPath | Set-Clipboard
    Write-Host "Database JSON successfully copied to clipboard for AI context injection." -ForegroundColor Cyan
}