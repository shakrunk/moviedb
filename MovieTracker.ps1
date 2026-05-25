<#
.SYNOPSIS
    Local PowerShell management engine for a self-documenting JSON movie log.

.DESCRIPTION
    Provides a CLI-friendly interface to manage a JSON-based movie database.
    It supports automated, parameter-driven execution (ideal for LLM-generated commands)
    as well as fully interactive wizards when executed without parameters.

.EXAMPLE
    Get-MovieEntry -SearchTerm 'Nolan'
    Audits the database for movies matching the search term.

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
    Update-MovieEntry Searching
    Triggers the interactive wizard to update a movie property, automatically mapping "Searching" to the title and providing a CLI menu for the property selection.
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

function Invoke-ChoiceMenu {
    <#
    .SYNOPSIS
        Internal helper for rendering an interactive, arrow-key driven CLI menu.
    #>
    param (
        [Parameter(Mandatory=$true)] [string]$Prompt,
        [Parameter(Mandatory=$true)] [string[]]$Choices
    )
    $selectedIndex = 0
    $cursorTop = [Console]::CursorTop

    # Hide terminal cursor for cleaner menu rendering
    try { [Console]::CursorVisible = $false } catch {}

    while ($true) {
        [Console]::SetCursorPosition(0, $cursorTop)
        Write-Host $Prompt -ForegroundColor Cyan

        for ($i = 0; $i -lt $Choices.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host "  ❯ $($Choices[$i])  " -ForegroundColor Cyan
            } else {
                Write-Host "    $($Choices[$i])  " -ForegroundColor DarkGray
            }
        }

        $key = [Console]::ReadKey($true).Key
        if ($key -eq 'UpArrow') {
            if ($selectedIndex -gt 0) { $selectedIndex-- }
        } elseif ($key -eq 'DownArrow') {
            if ($selectedIndex -lt ($Choices.Count - 1)) { $selectedIndex++ }
        } elseif ($key -eq 'Enter') {
            break
        }
    }

    # Restore cursor and log selection
    try { [Console]::CursorVisible = $true } catch {}
    Write-Host "Selected: $($Choices[$selectedIndex])`n" -ForegroundColor Green
    return $Choices[$selectedIndex]
}

function Get-MovieEntry {
    <#
    .SYNOPSIS
        Retrieves and audits movie entries from the data store.
    .DESCRIPTION
        Provides a read-only audit view of the movies.json database.
        Includes Nerd Font ligatures for rating visualization.
    #>
    [CmdletBinding()]
    param (
        [string]$SearchTerm
    )

    Initialize-MovieDatabase
    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json

    $Query = $RawJson.log
    if ($SearchTerm) {
        $Query = $Query | Where-Object {
            $_.Title -match $SearchTerm -or
            $_.Director -match $SearchTerm -or
            $_.Genre -match $SearchTerm
        }
    }

    $Query | Select-Object `
        @{Name="Title"; Expression={$_.Title}},
        @{Name="Year"; Expression={
            if ($_.ReleaseDate -match '(\d{4})') { $Matches[1] } else { "N/A" }
        }},
        @{Name="Rating"; Expression={
            if ($_.Rating) { "★" * $_.Rating + "☆" * (5 - $_.Rating) } else { "     " }
        }},
        @{Name="Director"; Expression={$_.Director}},
        @{Name="Genre"; Expression={$_.Genre}} |
        Format-Table -AutoSize
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

        $RatingChoices = @("Skip", "1 - Terrible", "2 - Bad", "3 - Okay", "4 - Good", "5 - Masterpiece")
        $ratingSelection = Invoke-ChoiceMenu -Prompt "Select Rating:" -Choices $RatingChoices
        if ($ratingSelection -ne "Skip") { $Rating = [int]($ratingSelection.Substring(0,1)) }

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
        Rating      = if ($PSBoundParameters.ContainsKey('Rating') -or $ratingSelection -ne "Skip") { $Rating } else { $null }
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
        [Parameter(Position = 0)] [string]$Title,
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

    # Duplicate Resolution Menu
    if ($TargetRecords.Count -gt 1) {
        $menuOptions = $TargetRecords | ForEach-Object {
            $year = if ($_.ReleaseDate -match '(\d{4})') { $Matches[1] } else { "Unknown" }
            "$($_.Title) ($year) - Director: $($_.Director)"
        }

        $selectionString = Invoke-ChoiceMenu -Prompt "Multiple entries found for '$Title'. Select the target record:" -Choices $menuOptions
        $selectedIndex = [array]::IndexOf($menuOptions, $selectionString)
        $SelectedRecord = $TargetRecords[$selectedIndex]
    }

    # Property Selection Menu
    if (-not $PSBoundParameters.ContainsKey('Property')) {
        $Properties = @('Rating', 'WatchDate', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')
        $Property = Invoke-ChoiceMenu -Prompt "Select property to update for '$Title':" -Choices $Properties
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
