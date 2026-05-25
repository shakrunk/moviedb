<#
.SYNOPSIS
    Local PowerShell management engine for a self-documenting JSON movie log.

.DESCRIPTION
    Provides a CLI-friendly interface to manage a JSON-based movie database.
    It supports automated, parameter-driven execution (ideal for LLM-generated commands)
    as well as fully interactive wizards when executed without parameters.

.EXAMPLE
    Add-MovieEntry -Title 'Dune' -Rating 5 -WatchDate '2024-03-01'
    Adds an entry silently using explicit parameters.

.EXAMPLE
    Add-MovieEntry
    Triggers the interactive wizard to add a new movie.

.EXAMPLE
    Update-MovieEntry -Title 'Inception' -Property 'Rating' -Value 5
    Updates the rating for Inception directly.

.EXAMPLE
    Update-MovieEntry
    Triggers the interactive wizard to update a movie property, including duplicate resolution.
#>

$Global:MovieDbPath = Join-Path $PSScriptRoot "movies.json"

function Initialize-MovieDatabase {
    <#
    .SYNOPSIS
        Validates the existence of the movie database file.
    #>
    [CmdletBinding()]
    param (
        [string]$Path = $Global:MovieDbPath
    )
    if (-not (Test-Path $Path)) {
        Throw "Database file not found at $Path. Please ensure the baseline movies.json is present."
    }
}

function Add-MovieEntry {
    <#
    .SYNOPSIS
        Appends a new movie record to the JSON data store.
    .DESCRIPTION
        If executed with the -Title parameter, it processes the request automatically.
        If executed without parameters, it falls back to an interactive prompt for all fields.
    #>
    [CmdletBinding()]
    param (
        [string]$Title,
        [ValidateRange(1, 5)] [int]$Rating,
        [string]$WatchDate,
        [string]$ReleaseDate,
        [string]$Runtime,
        [string]$Genre,
        [string]$Director,
        [string]$Studio,
        [string]$Actors,
        [string]$Notes = ""
    )

    Initialize-MovieDatabase
    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json

    # Interactive Wizard Fallback
    if (-not $PSBoundParameters.ContainsKey('Title')) {
        Write-Host "--- Add New Movie Entry ---" -ForegroundColor Cyan
        $Title = Read-Host "Title (Required)"
        if ([string]::IsNullOrWhiteSpace($Title)) {
            Write-Error "Title is mandatory. Aborting."
            return
        }

        $RatingInput = Read-Host "Rating (1-5) [Skip]"
        if ($RatingInput -match '^[1-5]$') { $Rating = [int]$RatingInput }

        $WatchDate   = Read-Host "WatchDate (YYYY-MM-DD) [Skip]"
        $ReleaseDate = Read-Host "ReleaseDate (YYYY-MM-DD) [Skip]"
        $Runtime     = Read-Host "Runtime (HH:MM:SS) [Skip]"
        $Genre       = Read-Host "Genre [Skip]"
        $Director    = Read-Host "Director [Skip]"
        $Studio      = Read-Host "Studio [Skip]"
        $Actors      = Read-Host "Actors [Skip]"
        $Notes       = Read-Host "Notes [Skip]"
    }

    if ($RawJson.log.Title -contains $Title) {
        Write-Warning "An entry for '$Title' already exists. Consider using Update-MovieEntry instead."
    }

    $NewRecord = [PSCustomObject]@{
        Title       = $Title
        Rating      = if ($PSBoundParameters.ContainsKey('Rating') -or $RatingInput) { $Rating } else { $null }
        WatchDate   = $WatchDate
        ReleaseDate = $ReleaseDate
        Runtime     = $Runtime
        Genre       = $Genre
        Director    = $Director
        Studio      = $Studio
        Actors      = $Actors
        Notes       = $Notes
    }

    $RawJson.log += $NewRecord
    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Successfully appended '$Title' to the data store." -ForegroundColor Green
}

function Update-MovieEntry {
    <#
    .SYNOPSIS
        Modifies a specific property of an existing movie entry.
    .DESCRIPTION
        If multiple movies share the same title, the function will pause and prompt
        the user to select the correct specific record to modify. Falls back to interactive
        prompts if no parameters are provided.
    #>
    [CmdletBinding()]
    param (
        [string]$Title,
        [ValidateSet('Rating', 'WatchDate', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')] [string]$Property,
        $Value
    )

    Initialize-MovieDatabase

    # Interactive Wizard Fallback
    if (-not $PSBoundParameters.ContainsKey('Title')) {
        Write-Host "--- Update Movie Entry ---" -ForegroundColor Cyan
        $Title = Read-Host "Enter Movie Title to update"
        if ([string]::IsNullOrWhiteSpace($Title)) { return }
    }

    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json
    $TargetRecords = @($RawJson.log | Where-Object { $_.Title -eq $Title })

    if ($TargetRecords.Count -eq 0) {
        Write-Error "Movie '$Title' not found in the data store."
        return
    }

    $SelectedRecord = $TargetRecords[0]

    # Duplicate Resolution Handling
    if ($TargetRecords.Count -gt 1) {
        Write-Host "`nMultiple entries found for '$Title'. Please select the target record:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $TargetRecords.Count; $i++) {
            $rec = $TargetRecords[$i]
            $year = if ($rec.ReleaseDate) { $rec.ReleaseDate } else { "Unknown Year" }
            $dir = if ($rec.Director) { $rec.Director } else { "Unknown Director" }
            Write-Host "  [$i] $Title ($year) - Director: $dir"
        }

        $Selection = Read-Host "`nEnter selection number"
        if ($Selection -match '^\d+$' -and [int]$Selection -lt $TargetRecords.Count) {
            $SelectedRecord = $TargetRecords[[int]$Selection]
        } else {
            Write-Error "Invalid selection. Aborting."
            return
        }
    }

    # Continue Interactive Fallback for Property/Value
    if (-not $PSBoundParameters.ContainsKey('Property')) {
        $Property = Read-Host "Property to update (Rating, WatchDate, ReleaseDate, Runtime, Genre, Director, Studio, Actors, Notes)"
        if ([string]::IsNullOrWhiteSpace($Property)) { return }
    }

    if (-not $PSBoundParameters.ContainsKey('Value')) {
        $Value = Read-Host "New value for $Property"
    }

    # Apply Type Casting & Update
    if ($Property -eq 'Rating') {
        $SelectedRecord.$Property = if ([string]::IsNullOrWhiteSpace($Value)) { $null } else { [int]$Value }
    } else {
        $SelectedRecord.$Property = [string]$Value
    }

    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Successfully updated $Property for '$Title'." -ForegroundColor Green
}

function Copy-MovieDbToClipboard {
    <#
    .SYNOPSIS
        Loads the current state of the JSON database into the system clipboard.
    #>
    [CmdletBinding()]
    param()
    Initialize-MovieDatabase
    Get-Content -Raw -Path $Global:MovieDbPath | Set-Clipboard
    Write-Host "Database JSON successfully copied to clipboard." -ForegroundColor Cyan
}
