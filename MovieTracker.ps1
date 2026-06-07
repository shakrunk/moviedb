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
    Get-MovieEntry -Detailed
    Audits the database and displays all available columns in the table.

.EXAMPLE
    Get-MovieEntry -Watchlist
    Shows only movies on the want-to-watch list.

.EXAMPLE
    Add-MovieEntry -Title 'Dune' -Status 'watched' -Rating 5 -WatchDate '2024-03-01'
    Adds an entry silently using explicit parameters (ideal for LLM-generated commands).

.EXAMPLE
    Add-MovieEntry
    Triggers the interactive wizard to add a new movie, including an option to fetch metadata online.

.EXAMPLE
    Update-MovieEntry Searching
    Triggers the interactive wizard to update a movie property, automatically mapping "Searching" to the title and providing a CLI menu for the property selection.

.EXAMPLE
    Mark-MovieWatched -Title 'Arrival' -WatchDate '2025-02-14'
    Atomically marks a movie as watched and records the date.

.EXAMPLE
    Copy-MovieDbToClipboard
    Copies a token-minimized export of the database, plus the embedded LLM command reference, to the clipboard for pasting into a chat assistant.
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
        Supports graceful exit via the Escape key and alphanumeric quick-jumping/auto-submission.
    .PARAMETER Prompt
        The instructional text displayed above the menu choices.
    .PARAMETER Choices
        An array of string options presented to the user.
    .OUTPUTS
        Returns the selected string from the Choices array, or $null if cancelled.
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
        Write-Host "$Prompt (Esc to cancel)" -ForegroundColor Cyan

        for ($i = 0; $i -lt $Choices.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host "  ❯ $($Choices[$i])  " -ForegroundColor Cyan
            } else {
                Write-Host "    $($Choices[$i])  " -ForegroundColor DarkGray
            }
        }

        $keyInfo = [Console]::ReadKey($true)
        $key = $keyInfo.Key
        $char = $keyInfo.KeyChar

        if ($key -eq 'Escape') {
            try { [Console]::CursorVisible = $true } catch {}
            Write-Host "`nOperation cancelled by user.`n" -ForegroundColor Yellow
            return $null
        } elseif ($key -eq 'UpArrow') {
            if ($selectedIndex -gt 0) { $selectedIndex-- }
        } elseif ($key -eq 'DownArrow') {
            if ($selectedIndex -lt ($Choices.Count - 1)) { $selectedIndex++ }
        } elseif ($key -eq 'Enter') {
            break
        } elseif ($char -match '^[a-zA-Z0-9]$') {
            # Jump to the first choice starting with the typed character
            for ($i = 0; $i -lt $Choices.Count; $i++) {
                if ($Choices[$i] -match "^$char") {
                    $selectedIndex = $i
                    # Auto-submit if a number was typed and matched
                    if ($char -match '^[0-9]$') {
                        break
                    }
                }
            }
            if ($char -match '^[0-9]$' -and $Choices[$selectedIndex] -match "^$char") {
                break
            }
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
        Includes Nerd Font star ligatures for quick visual parsing of ratings, and supports
        free-text search, status filtering, rating thresholds, and sorting. A summary footer
        reports the number of matches and the average rating of the rated entries.
    .PARAMETER SearchTerm
        An optional regex string to filter the datastore. Matched against Title, Director, Genre,
        Actors, Studio, and Notes.
    .PARAMETER Detailed
        Switch to bypass the summarized view and display all available columns in the table.
    .PARAMETER Column
        Explicit list of columns to display, in the order given. Overrides both the summary view and
        -Detailed. Valid columns: Title, Year, Status, Rating, WatchDate, PriorWatch, ReleaseDate,
        Runtime, Genre, Director, Studio, Actors, Notes.
    .PARAMETER StatusFilter
        Only return entries with this Status value. Valid values: watched, watched_no_date, want_to_watch.
    .PARAMETER Watchlist
        Shortcut for -StatusFilter want_to_watch. Shows only movies you haven't seen yet.
    .PARAMETER MinRating
        Only return entries rated at or above this value (1-5). Unrated entries are excluded.
    .PARAMETER SortBy
        Column to order results by: Title, Year, Rating, or WatchDate. Defaults to the datastore's
        natural insertion order.
    .PARAMETER Descending
        Reverses the sort direction. Has no effect unless -SortBy is also specified.
    .EXAMPLE
        Get-MovieEntry
        Returns all tracked movies.
    .EXAMPLE
        Get-MovieEntry -SearchTerm "Nolan"
        Returns entries matching "Nolan" in any of Title, Director, Genre, Actors, Studio, or Notes.
    .EXAMPLE
        Get-MovieEntry -Watchlist
        Returns only movies on the want-to-watch list.
    .EXAMPLE
        Get-MovieEntry -StatusFilter watched_no_date
        Returns movies that were watched before the log was started.
    .EXAMPLE
        Get-MovieEntry -MinRating 4 -SortBy Rating -Descending
        Returns your 4- and 5-star films, highest rated first.
    .EXAMPLE
        Get-MovieEntry -SortBy Year
        Returns all movies ordered by release year (oldest first).
    .EXAMPLE
        Get-MovieEntry -Detailed
        Expands the output table to include Status, WatchDate, Runtime, Studio, Actors, and Notes.
    .EXAMPLE
        Get-MovieEntry -Column Title, Status, WatchDate, Runtime
        Displays only the chosen columns, in the order specified.
    #>
    [CmdletBinding()]
    param (
        [string]$SearchTerm,
        [switch]$Detailed,
        [ValidateSet('Title', 'Year', 'Status', 'Rating', 'WatchDate', 'PriorWatch', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')]
        [string[]]$Column,
        [ValidateSet('watched', 'watched_no_date', 'want_to_watch')] [string]$StatusFilter,
        [switch]$Watchlist,
        [ValidateRange(1, 5)] [int]$MinRating,
        [ValidateSet('Title', 'Year', 'Rating', 'WatchDate')] [string]$SortBy,
        [switch]$Descending
    )

    Initialize-MovieDatabase
    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json

    $Query = $RawJson.log
    if ($SearchTerm) {
        $Query = $Query | Where-Object {
            $_.Title -match $SearchTerm -or
            $_.Director -match $SearchTerm -or
            $_.Genre -match $SearchTerm -or
            $_.Actors -match $SearchTerm -or
            $_.Studio -match $SearchTerm -or
            $_.Notes -match $SearchTerm
        }
    }

    if ($Watchlist) {
        $Query = $Query | Where-Object { $_.Status -eq 'want_to_watch' }
    } elseif ($StatusFilter) {
        $Query = $Query | Where-Object { $_.Status -eq $StatusFilter }
    }

    if ($PSBoundParameters.ContainsKey('MinRating')) {
        $Query = $Query | Where-Object { $_.Rating -and $_.Rating -ge $MinRating }
    }

    if ($SortBy) {
        # Year sorts on the parsed release year; Rating coerces null to 0; others sort by property name
        $sortKey = switch ($SortBy) {
            'Year'      { { if ($_.ReleaseDate -match '(\d{4})') { [int]$Matches[1] } else { 0 } } }
            'Rating'    { { [int]$_.Rating } }
            'WatchDate' { { @($_.WatchDate | Sort-Object)[-1] } }  # sort by most recent watch
            default     { $SortBy }
        }
        $Query = $Query | Sort-Object $sortKey -Descending:$Descending
    }

    $Results = @($Query)
    if ($Results.Count -eq 0) {
        Write-Host "No matching movie entries found." -ForegroundColor Yellow
        return
    }

    # Column rendering map. Status renders as a compact glyph. Year is derived from ReleaseDate.
    # Rating renders as stars. WatchDate is joined for clean display of re-watches.
    $ColumnMap = @{
        'Title'       = @{Name="Title";       Expression={ $_.Title }}
        'Year'        = @{Name="Year";        Expression={ if ($_.ReleaseDate -match '(\d{4})') { $Matches[1] } else { "N/A" } }}
        'Status'      = @{Name="Status";      Expression={
            switch ($_.Status) {
                'watched'          { '✓' }
                'watched_no_date'  { '✓?' }
                'want_to_watch'    { '◯' }
                default            { $_.Status }
            }
        }}
        'Rating'      = @{Name="Rating";      Expression={ if ($_.Rating) { "★" * $_.Rating + "☆" * (5 - $_.Rating) } else { "     " } }}
        'WatchDate'   = @{Name="WatchDate";   Expression={ @($_.WatchDate) -join ', ' }}
        'PriorWatch'  = @{Name="PriorWatch";  Expression={
            if ($null -eq $_.PriorWatch) { '?' }
            elseif ($_.PriorWatch -eq $true) { 'rewatch' }
            else { 'first time' }
        }}
        'ReleaseDate' = @{Name="ReleaseDate"; Expression={ $_.ReleaseDate }}
        'Runtime'     = @{Name="Runtime";     Expression={ $_.Runtime }}
        'Genre'       = @{Name="Genre";       Expression={ $_.Genre }}
        'Director'    = @{Name="Director";    Expression={ $_.Director }}
        'Studio'      = @{Name="Studio";      Expression={ $_.Studio }}
        'Actors'      = @{Name="Actors";      Expression={ $_.Actors }}
        'Notes'       = @{Name="Notes";       Expression={ $_.Notes }}
    }

    # Resolve which columns to show: explicit -Column wins, then -Detailed (all), else the summary set.
    if ($Column) {
        $SelectedColumns = $Column
    } elseif ($Detailed) {
        $SelectedColumns = 'Title', 'Year', 'Status', 'Rating', 'WatchDate', 'PriorWatch', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes'
    } else {
        $SelectedColumns = 'Title', 'Year', 'Status', 'Rating', 'Director', 'Genre'
    }

    $Expressions = $SelectedColumns | ForEach-Object { $ColumnMap[$_] }
    if ($Column -or $Detailed) {
        $Results | Select-Object $Expressions | Format-Table -AutoSize -Wrap | Out-Host
    } else {
        $Results | Select-Object $Expressions | Format-Table -AutoSize | Out-Host
    }

    # Summary footer: match count + average of the rated entries
    $Rated = @($Results | Where-Object { $_.Rating })
    $Summary = "$($Results.Count) " + $(if ($Results.Count -eq 1) { "entry" } else { "entries" })
    if ($Rated.Count -gt 0) {
        $Avg = [math]::Round(($Rated | Measure-Object -Property Rating -Average).Average, 1)
        $Summary += "  ·  avg rating $Avg/5 across $($Rated.Count) rated"
    }
    Write-Host $Summary -ForegroundColor DarkGray
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
    .PARAMETER Status
        Watch status: 'watched' (seen, WatchDate known), 'watched_no_date' (seen before this log
        was started, date unknown), or 'want_to_watch' (not yet seen). Defaults to 'watched' if
        WatchDate is provided, 'watched_no_date' otherwise.
    .PARAMETER Rating
        User rating from 1 to 5.
    .PARAMETER WatchDate
        One or more dates the movie was watched (YYYY-MM-DD). Accepts multiple values to record
        re-watches, e.g. -WatchDate '2024-03-01','2025-01-10'. Stored as an array.
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
    .PARAMETER PriorWatch
        Whether the movie was seen before this log was started. $true = already seen before (this
        watch is a re-watch), $false = genuine first-ever viewing. Omit for want_to_watch entries
        or when unknown. Automatically set to $true for watched_no_date entries.
    .PARAMETER Notes
        Any personal notes or reviews.
    .EXAMPLE
        Add-MovieEntry -Title 'Dune' -Status 'watched' -Rating 5 -WatchDate '2024-03-01' -PriorWatch $false
        Silently appends a first-time watch using explicit parameters (ideal for LLM-generated commands).
    .EXAMPLE
        Add-MovieEntry -Title 'Dune: Part Three' -Status 'want_to_watch'
        Adds a movie to the watchlist without a rating or date.
    .EXAMPLE
        Add-MovieEntry
        Launches the interactive wizard, including an optional iTunes metadata lookup.
    #>
    [CmdletBinding()]
    param (
        [string]$Title,
        [ValidateSet('watched', 'watched_no_date', 'want_to_watch')] [string]$Status,
        [ValidateRange(1, 5)] [int]$Rating,
        [string[]]$WatchDate,
        [string]$ReleaseDate,
        [string]$Runtime,
        [string]$Genre,
        [string]$Director,
        [string]$Studio,
        [string]$Actors,
        [string]$Notes = "",
        [System.Nullable[bool]]$PriorWatch
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
        if (-not $FetchOnline) { return }

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
                    if (-not $selection) { return }

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

        # Status selection drives the rest of the wizard flow
        $statusSelection = Invoke-ChoiceMenu -Prompt "Have you seen this movie?" -Choices @(
            "Watched — I know the date",
            "Watched — I don't know the date",
            "Want to Watch — haven't seen it yet"
        )
        if (-not $statusSelection) { return }

        $ratingSelection = $null

        if ($statusSelection -eq "Watched — I know the date") {
            $Status = 'watched'
            $WatchDate = Read-Host "WatchDate (YYYY-MM-DD)"

            $RatingChoices = @("Skip", "1 - Terrible", "2 - Bad", "3 - Okay", "4 - Good", "5 - Masterpiece")
            $ratingSelection = Invoke-ChoiceMenu -Prompt "Select Rating:" -Choices $RatingChoices
            if (-not $ratingSelection) { return }
            if ($ratingSelection -ne "Skip") { $Rating = [int]($ratingSelection.Substring(0,1)) }

            $priorWatchSelection = Invoke-ChoiceMenu -Prompt "Have you seen this movie before?" -Choices @(
                "No — this is my first time ever watching it",
                "Yes — I've seen it before (this is a re-watch)"
            )
            if (-not $priorWatchSelection) { return }
            $PriorWatch = $priorWatchSelection -eq "Yes — I've seen it before (this is a re-watch)"

        } elseif ($statusSelection -eq "Watched — I don't know the date") {
            $Status = 'watched_no_date'
            $WatchDate = $null
            $PriorWatch = $true   # If date is unknown, the watch predates this system — inherently a prior watch

            $RatingChoices = @("Skip", "1 - Terrible", "2 - Bad", "3 - Okay", "4 - Good", "5 - Masterpiece")
            $ratingSelection = Invoke-ChoiceMenu -Prompt "Select Rating:" -Choices $RatingChoices
            if (-not $ratingSelection) { return }
            if ($ratingSelection -ne "Skip") { $Rating = [int]($ratingSelection.Substring(0,1)) }

        } else {
            $Status = 'want_to_watch'
            $WatchDate = $null
            $ratingSelection = "Skip"
        }

        # Helper to show default value if metadata was fetched
        function Get-PromptInput ([string]$Field, [string]$DefaultValue) {
            $promptText = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "$Field [Skip]" } else { "$Field [$DefaultValue]" }
            $inputVal = Read-Host $promptText
            if ([string]::IsNullOrWhiteSpace($inputVal)) { return $DefaultValue } else { return $inputVal }
        }

        $ReleaseDate = Get-PromptInput "ReleaseDate (YYYY-MM-DD)" $ReleaseDate
        $Runtime     = Get-PromptInput "Runtime (HH:MM:SS)" $Runtime
        $Genre       = Get-PromptInput "Genre" $Genre
        $Director    = Get-PromptInput "Director" $Director
        $Studio      = Get-PromptInput "Studio" ""
        $Actors      = Get-PromptInput "Actors" ""
        $Notes       = Get-PromptInput "Notes" ""
    }

    # Non-interactive default: infer Status from WatchDate when not explicitly provided
    if (-not $PSBoundParameters.ContainsKey('Status') -and [string]::IsNullOrWhiteSpace($Status)) {
        $hasDate = @($WatchDate | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
        $Status = if ($hasDate) { 'watched' } else { 'watched_no_date' }
    }

    # watched_no_date always implies the movie was seen before this system — coerce PriorWatch accordingly
    if ($Status -eq 'watched_no_date' -and $null -eq $PriorWatch) {
        $PriorWatch = $true
    }

    if ($RawJson.log.Title -contains $Title) {
        Write-Warning "An entry for '$Title' already exists. Consider using Update-MovieEntry instead."
    }

    $NewRecord = [PSCustomObject]@{
        Title       = $Title
        Rating      = if ($PSBoundParameters.ContainsKey('Rating') -or ($ratingSelection -and $ratingSelection -ne "Skip")) { $Rating } else { $null }
        WatchDate   = @($WatchDate | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Status      = $Status
        PriorWatch  = $PriorWatch
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
    Write-Host "Successfully appended '$Title' ($Status) to the data store." -ForegroundColor Green
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
        The exact property schema key to mutate (e.g., Status, Rating, WatchDate, Notes).
    .PARAMETER Value
        The new value to assign to the property. For WatchDate (an array field) the value is
        appended to the existing list of watch dates rather than replacing it; pass an empty value
        to clear all watch dates.
    .EXAMPLE
        Update-MovieEntry -Title 'Interstellar' -Property 'Rating' -Value 5
        Silently updates a single property using explicit parameters.
    .EXAMPLE
        Update-MovieEntry -Title 'Arrival' -Property 'Status' -Value 'want_to_watch'
        Changes the status of a movie.
    .EXAMPLE
        Update-MovieEntry -Title 'Inception' -Property 'WatchDate' -Value '2025-05-30'
        Appends a watch date — recording a re-watch — to Inception's WatchDate list.
    .EXAMPLE
        Update-MovieEntry Searching
        Launches the interactive wizard for "Searching", presenting a menu of properties (with their current values) to update.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)] [string]$Title,
        [ValidateSet('Status', 'Rating', 'WatchDate', 'PriorWatch', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')] [string]$Property,
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
        if (-not $selectionString) { return }

        $selectedIndex = [array]::IndexOf($menuOptions, $selectionString)
        $SelectedRecord = $TargetRecords[$selectedIndex]
    }

    # Property Selection Menu
    if (-not $PSBoundParameters.ContainsKey('Property')) {
        $Properties = @('Status', 'Rating', 'WatchDate', 'PriorWatch', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')

        # Build display choices showing the current value of each property
        $DisplayChoices = $Properties | ForEach-Object {
            $val = $SelectedRecord.$_
            if ($val -is [array]) { $val = $val -join ', ' }
            if ($null -eq $val -or $val -eq "") { $val = "<empty>" }
            "$_ (Current: $val)"
        }

        $ChoiceStr = Invoke-ChoiceMenu -Prompt "Select property to update for '$($SelectedRecord.Title)':" -Choices $DisplayChoices
        if (-not $ChoiceStr) { return }

        $selectedIndex = [array]::IndexOf($DisplayChoices, $ChoiceStr)
        $Property = $Properties[$selectedIndex]
    }

    if (-not $PSBoundParameters.ContainsKey('Value')) {
        $currentVal = $SelectedRecord.$Property
        if ($currentVal -is [array]) { $currentVal = $currentVal -join ', ' }
        if ($null -eq $currentVal -or $currentVal -eq "") { $currentVal = "<empty>" }

        if ($Property -eq 'Rating') {
            $RatingChoices = @("Clear Rating", "1 - Terrible", "2 - Bad", "3 - Okay", "4 - Good", "5 - Masterpiece")
            $ratingSelection = Invoke-ChoiceMenu -Prompt "Select new Rating (Current: $currentVal):" -Choices $RatingChoices

            if (-not $ratingSelection) { return }

            if ($ratingSelection -eq "Clear Rating") {
                $Value = ""
            } else {
                $Value = $ratingSelection.Substring(0,1)
            }
        } elseif ($Property -eq 'Status') {
            $statusSelection = Invoke-ChoiceMenu -Prompt "Select new Status (Current: $currentVal):" -Choices @('watched', 'watched_no_date', 'want_to_watch')
            if (-not $statusSelection) { return }
            $Value = $statusSelection
        } elseif ($Property -eq 'PriorWatch') {
            $pwSelection = Invoke-ChoiceMenu -Prompt "Was this a re-watch or first time? (Current: $currentVal):" -Choices @(
                'false — first time ever watching',
                'true — seen it before (re-watch)'
            )
            if (-not $pwSelection) { return }
            $Value = if ($pwSelection -like 'true*') { $true } else { $false }
        } elseif ($Property -eq 'WatchDate') {
            $Value = Read-Host "Add a WatchDate to '$($SelectedRecord.Title)' — appends to the list; blank clears all (Current: $currentVal)"
        } else {
            $Value = Read-Host "New value for $Property (Current: $currentVal)"
        }
    }

    if ($Property -eq 'Rating') {
        $SelectedRecord.$Property = if ([string]::IsNullOrWhiteSpace($Value)) { $null } else { [int]$Value }
    } elseif ($Property -eq 'PriorWatch') {
        # Store as a JSON boolean, not a string
        if ($Value -is [bool]) {
            $SelectedRecord.PriorWatch = $Value
        } elseif ([string]::IsNullOrWhiteSpace([string]$Value)) {
            $SelectedRecord.PriorWatch = $null
        } else {
            $SelectedRecord.PriorWatch = [System.Convert]::ToBoolean($Value)
        }
    } elseif ($Property -eq 'WatchDate') {
        # WatchDate is an array: a non-empty value is appended (deduped + sorted); a blank value clears it.
        $incoming = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($incoming.Count -eq 0) {
            $SelectedRecord.WatchDate = @()
        } else {
            $existing = @($SelectedRecord.WatchDate | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $SelectedRecord.WatchDate = @(($existing + $incoming) | Sort-Object -Unique)
        }
    } else {
        $SelectedRecord.$Property = [string]$Value
    }

    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Successfully updated $Property for '$($SelectedRecord.Title)'." -ForegroundColor Green
}

function Mark-MovieWatched {
    <#
    .SYNOPSIS
        Atomically marks a want-to-watch (or watched_no_date) entry as watched with a date.
    .DESCRIPTION
        Convenience function that sets Status to 'watched' and appends the given date to WatchDate
        in a single operation. Avoids needing two separate Update-MovieEntry calls.
    .PARAMETER Title
        The title of the movie to mark as watched.
    .PARAMETER WatchDate
        The date it was watched (YYYY-MM-DD). Defaults to today if omitted.
    .PARAMETER PriorWatch
        Whether the movie was seen before this log. $true = re-watch (seen before), $false = first
        time ever. Inferred automatically from prior Status when possible (watched_no_date → $true).
        For want_to_watch entries the wizard will ask if not supplied.
    .EXAMPLE
        Mark-MovieWatched -Title 'Arrival'
        Marks Arrival as watched today.
    .EXAMPLE
        Mark-MovieWatched -Title 'Arrival' -WatchDate '2025-02-14'
        Marks Arrival as watched on Valentine's Day.
    .EXAMPLE
        Mark-MovieWatched -Title 'Inception' -WatchDate '2026-06-06' -PriorWatch $true
        Records a re-watch of a movie that was tracked without a date.
    .EXAMPLE
        Mark-MovieWatched Arrival
        Interactive wizard: prompts for the date and whether it's a first-time or re-watch.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)] [string]$Title,
        [string]$WatchDate,
        [System.Nullable[bool]]$PriorWatch
    )

    Initialize-MovieDatabase

    # Interactive Wizard Fallback
    if (-not $PSBoundParameters.ContainsKey('Title')) {
        Write-Host "--- Mark Movie as Watched ---" -ForegroundColor Cyan
        $Title = Read-Host "Enter Movie Title"
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
        if (-not $selectionString) { return }
        $selectedIndex = [array]::IndexOf($menuOptions, $selectionString)
        $SelectedRecord = $TargetRecords[$selectedIndex]
    }

    if (-not $PSBoundParameters.ContainsKey('WatchDate')) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $inputDate = Read-Host "Watch date [Enter for today: $today]"
        $WatchDate = if ([string]::IsNullOrWhiteSpace($inputDate)) { $today } else { $inputDate }
    }

    # Infer PriorWatch from existing status when not supplied:
    #   watched_no_date → already seen before, so this is definitively a re-watch ($true)
    #   want_to_watch   → ask the user if not explicitly passed
    if ($null -eq $PriorWatch) {
        if ($SelectedRecord.Status -eq 'watched_no_date') {
            $PriorWatch = $true
        } elseif ($SelectedRecord.Status -eq 'want_to_watch') {
            $priorWatchSelection = Invoke-ChoiceMenu -Prompt "Have you seen this movie before?" -Choices @(
                "No — this is my first time ever watching it",
                "Yes — I've seen it before (this is a re-watch)"
            )
            if ($priorWatchSelection) {
                $PriorWatch = $priorWatchSelection -eq "Yes — I've seen it before (this is a re-watch)"
            }
        }
    }

    $SelectedRecord.Status = 'watched'
    $existing = @($SelectedRecord.WatchDate | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $SelectedRecord.WatchDate = @(($existing + $WatchDate) | Sort-Object -Unique)
    if ($null -ne $PriorWatch) {
        $SelectedRecord.PriorWatch = $PriorWatch
    }

    $RawJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath
    Write-Host "Marked '$($SelectedRecord.Title)' as watched on $WatchDate." -ForegroundColor Green
}

function Copy-MovieDbToClipboard {
    <#
    .SYNOPSIS
        Copies a token-minimized export of the movie database to the system clipboard for pasting into an LLM.
    .DESCRIPTION
        Trims every record down to the fields an LLM needs to identify a movie, understand your
        opinion of it, and know its watch status (Title, ReleaseDate, WatchDate, Status, Rating, Notes).
        Status is always included so LLMs can correctly distinguish watched, watched_no_date, and
        want_to_watch entries without misinterpreting an empty WatchDate as "unwatched".

        By default the export also includes the database's embedded `_metadata` block — the
        self-documenting command reference (Add-MovieEntry / Update-MovieEntry / Mark-MovieWatched /
        Get-MovieEntry syntax). Keeping this alongside the data lets the LLM not only read your
        library but also generate the exact PowerShell commands needed to mutate it, without you
        having to re-explain the schema each time.

        Use -DataOnly to omit that reference and copy just the minimized array of records — the
        smallest possible payload. This is useful when the LLM already has the command reference
        in context (or when you only want it to analyze the data, not modify it).
    .PARAMETER DataOnly
        Copies only the minimized array of movie records, stripping the `_metadata` command reference.
        Produces the smallest payload at the cost of the LLM no longer knowing the available mutation
        commands.
    .EXAMPLE
        Copy-MovieDbToClipboard
        Copies the minimized library plus the embedded LLM command reference to the clipboard.
    .EXAMPLE
        Copy-MovieDbToClipboard -DataOnly
        Copies just the minimized array of records, omitting the command reference for maximum brevity.
    #>
    [CmdletBinding()]
    param(
        [switch]$DataOnly
    )
    Initialize-MovieDatabase

    $RawJson = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json

    # Include Status, WatchDate, and PriorWatch so LLMs can correctly interpret the watch history.
    # Status disambiguates watched_no_date (seen before log started) from want_to_watch (unseen).
    # PriorWatch distinguishes a genuine first-ever viewing from a re-watch of a previously seen film.
    $MinimizedLog = $RawJson.log | Select-Object Title, ReleaseDate, WatchDate, Status, PriorWatch, Rating, Notes
    $RecordCount = @($MinimizedLog).Count

    if ($DataOnly) {
        # Bare minimized array, no command reference
        $Payload = $MinimizedLog
        $Summary = "Minimized database JSON ($RecordCount records) copied to clipboard."
    } else {
        # Preserve the self-documenting command reference so the LLM can generate mutation commands
        $Payload = [PSCustomObject]@{
            _metadata = $RawJson._metadata
            log       = $MinimizedLog
        }
        $Summary = "Minimized database JSON ($RecordCount records) + LLM command reference copied to clipboard."
    }

    $Payload | ConvertTo-Json -Depth 10 | Set-Clipboard
    Write-Host $Summary -ForegroundColor Cyan
}
