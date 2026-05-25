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
    Triggers the interactive wizard to add a new movie, including an option to fetch metadata online.

.EXAMPLE
    Update-MovieEntry Searching
    Triggers the interactive wizard to update a movie property, automatically mapping "Searching" to the title and providing a CLI menu for the property selection.
#>

$Global:MovieDbPath = Join-Path $PSScriptRoot "movies.json"

function Initialize-MovieDatabase {
    <#
    .SYNOPSIS
        Validates the existence of the movie database file.
    .DESCRIPTION
        Checks the script's root directory for the `movies.json` datastore.
        Throws a terminating error if the file is missing to prevent corrupted state executions.
    .PARAMETER Path
        The absolute path to the JSON database. Defaults to the script root.
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
    .DESCRIPTION
        Utilizes the [System.Console] class to capture raw keystrokes and redraw the terminal buffer,
        providing a smooth selection interface without requiring native PromptForChoice windowpopups.
    .PARAMETER Prompt
        The instructional text displayed above the menu choices.
    .PARAMETER Choices
        An array of string options presented to the user.
    .OUTPUTS
        Returns the selected string from the Choices array.
    #>
    [CmdletBinding()]
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
        Provides a read-only, formatted table view of the movies.json database.
        Includes Nerd Font star ligatures for quick visual parsing of ratings.
    .PARAMETER SearchTerm
        An optional string to filter the datastore by Title, Director, or Genre using regex matching.
    .EXAMPLE
        Get-MovieEntry
        Returns all tracked movies.
    .EXAMPLE
        Get-MovieEntry -SearchTerm "Sci-Fi"
        Returns only entries matching the genre or title "Sci-Fi".
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
        Allows manual parameter entry for automation. If executed without parameters, triggers
        an interactive wizard that includes an optional metadata fetch via the public iTunes API.
    .PARAMETER Title
        The title of the movie. Mandatory.
    .PARAMETER Rating
        User rating from 1 to 5.
    .PARAMETER WatchDate
        The date the movie was watched (YYYY-MM-DD).
    .PARAMETER ReleaseDate
        The release date of the movie (YYYY-MM-DD).
    .PARAMETER Runtime
        The length of the movie (HH:MM:SS).
    .PARAMETER Genre
        Comma separated list of genres.
    .PARAMETER Director
        The director(s) of the movie.
    .PARAMETER Studio
        The production studio.
    .PARAMETER Actors
        Comma separated list of main actors.
    .PARAMETER Notes
        Any personal notes or reviews.
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

        # Attempt Online Metadata Fetch
        $FetchOnline = Invoke-ChoiceMenu -Prompt "Attempt to fetch metadata online?" -Choices @("Yes", "No")
        if ($FetchOnline -eq "Yes") {
            try {
                Write-Host "Searching iTunes Movie API..." -ForegroundColor DarkGray
                $uri = "https://itunes.apple.com/search?term=$([uri]::EscapeDataString($Title))&entity=movie&limit=5"
                $results = Invoke-RestMethod -Uri $uri

                if ($results.resultCount -gt 0) {
                    $options = @()
                    foreach ($res in $results.results) {
                        $year = if ($res.releaseDate) { $res.releaseDate.Substring(0,4) } else { "Unknown" }
                        $options += "$($res.trackName) ($year) - $($res.directorName)"
                    }
                    $options += "None of these"
                    $selection = Invoke-ChoiceMenu -Prompt "Select the matching movie:" -Choices $options

                    if ($selection -ne "None of these") {
                        $idx = [array]::IndexOf($options, $selection)
                        $match = $results.results[$idx]

                        if ($match.releaseDate) { $ReleaseDate = $match.releaseDate.Substring(0,10) }
                        if ($match.primaryGenreName) { $Genre = $match.primaryGenreName }
                        if ($match.directorName) { $Director = $match.directorName }
                        if ($match.trackTimeMillis) {
                            $ts = [TimeSpan]::FromMilliseconds($match.trackTimeMillis)
                            $Runtime = '{0:hh\:mm\:ss}' -f $ts
                        }
                        Write-Host "Metadata auto-filled where available.`n" -ForegroundColor Green
                    }
                } else {
                    Write-Warning "No online results found."
                }
            } catch {
                Write-Warning "Failed to query online metadata."
            }
        }

        $RatingChoices = @("Skip", "1 - Terrible", "2 - Bad", "3 - Okay", "4 - Good", "5 - Masterpiece")
        $ratingSelection = Invoke-ChoiceMenu -Prompt "Select Rating:" -Choices $RatingChoices
        if ($ratingSelection -ne "Skip") { $Rating = [int]($ratingSelection.Substring(0,1)) }

        # Helper to show default value if metadata was fetched
        function Get-PromptInput ([string]$Field, [string]$DefaultValue) {
            $promptText = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "$Field [Skip]" } else { "$Field [$DefaultValue]" }
            $inputVal = Read-Host $promptText
            return if ([string]::IsNullOrWhiteSpace($inputVal)) { $DefaultValue } else { $inputVal }
        }

        $WatchDate   = Get-PromptInput "WatchDate (YYYY-MM-DD)" ""
        $ReleaseDate = Get-PromptInput "ReleaseDate (YYYY-MM-DD)" $ReleaseDate
        $Runtime     = Get-PromptInput "Runtime (HH:MM:SS)" $Runtime
        $Genre       = Get-PromptInput "Genre" $Genre
        $Director    = Get-PromptInput "Director" $Director
        $Studio      = Get-PromptInput "Studio" ""
        $Actors      = Get-PromptInput "Actors" ""
        $Notes       = Get-PromptInput "Notes" ""
    }

    if ($RawJson.log.Title -contains $Title) {
        Write-Warning "An entry for '$Title' already exists. Consider using Update-MovieEntry instead."
    }

    $NewRecord = [PSCustomObject]@{
        Title       = $Title
        Rating      = if ($PSBoundParameters.ContainsKey('Rating') -or ($ratingSelection -and $ratingSelection -ne "Skip")) { $Rating } else { $null }
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
        Updates individual properties on records. Handles duplicate movie titles by dropping into
        an interactive selection menu, allowing you to pick the specific entry to mutate based on Year/Director.
    .PARAMETER Title
        The title of the movie to update.
    .PARAMETER Property
        The exact property schema key to mutate (e.g., Rating, WatchDate, Notes).
    .PARAMETER Value
        The new value to assign to the property.
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
        Minimizes and loads the JSON database into the system clipboard.
    .DESCRIPTION
        Strips away system metadata, schema instructions, and unneeded fields (Actors, Genre, etc.)
        before converting back to JSON and copying to the clipboard. This maximizes token efficiency
        when pasting the dataset into LLMs for context mapping.
    #>
    [CmdletBinding()]
    param()
    Initialize-MovieDatabase

    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json

    # Strip down to only what is necessary for the LLM to identify the movie and understand your notes/rating
    $ExportData = $RawJson.log | Select-Object Title, ReleaseDate, Rating, Notes

    $ExportData | ConvertTo-Json -Depth 10 | Set-Clipboard
    Write-Host "Minimized Database JSON successfully copied to clipboard." -ForegroundColor Cyan
}
