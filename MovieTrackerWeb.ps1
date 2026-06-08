<#
.SYNOPSIS
    Local web server + launcher for THE PROJECTION ROOM — a sleek, modern web GUI for the
    movies.json data store.

.DESCRIPTION
    Starts a tiny self-contained HTTP server (System.Net.HttpListener) that serves the
    single-page web app under .\web and exposes a small JSON API for reading and mutating
    the SAME movies.json database driven by MovieTracker.ps1.

    It reads and writes the identical file, preserving the embedded _metadata command
    reference and writing every record in the canonical field order used by the CLI's
    Add-MovieEntry (Title, Rating, WatchDate, Status, PriorWatch, ReleaseDate, Runtime,
    Genre, Director, Studio, Actors, Notes). The web GUI and the CLI therefore stay
    perfectly in sync.

    Only what ships with Windows is required: PowerShell + a modern browser. No build step,
    no npm, no external runtime. iTunes metadata/poster lookups are an optional online
    enhancement; the app is fully functional and beautiful offline.

    Launch by double-clicking, right-click -> "Run with PowerShell", or:
        pwsh -ExecutionPolicy Bypass -File .\MovieTrackerWeb.ps1

.PARAMETER Port
    TCP port to listen on (localhost only). Defaults to 7777; if busy, the next free port
    is chosen automatically.

.PARAMETER NoBrowser
    Start the server without auto-opening the default browser.
#>
[CmdletBinding()]
param(
    [int]$Port = 7777,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------------------------
$script:Root      = $PSScriptRoot
$script:DbPath    = Join-Path $script:Root 'movies.json'
$script:WebRoot   = Join-Path $script:Root 'web'
$script:CacheDir  = Join-Path $script:Root '.cache'
$script:PosterDb  = Join-Path $script:CacheDir 'posters.json'

# Canonical record field order — matches MovieTracker.ps1 Add-MovieEntry output exactly.
$script:FieldOrder = @('Title','Rating','WatchDate','Status','PriorWatch','ReleaseDate','Runtime','Genre','Director','Studio','Actors','Notes')
$script:ValidStatus = @('watched','watched_no_date','want_to_watch')

if (-not (Test-Path $script:CacheDir)) { New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null }

# iTunes is an optional, often-flaky online dependency. A circuit breaker keeps a dead API from
# blocking the single-threaded server: once a call fails, we fast-fail every automatic lookup for
# a short cooldown instead of waiting on the network timeout again and again.
$script:ITunesDownUntil = $null

# --- Data layer --------------------------------------------------------------------------------

function Read-Db {
    if (-not (Test-Path $script:DbPath)) {
        throw "Database file not found at $script:DbPath"
    }
    return (Get-Content -Raw -Path $script:DbPath | ConvertFrom-Json)
}

function ConvertTo-CanonicalRecord {
    # Coerce an arbitrary incoming object (from JSON request body, or an existing record) into a
    # canonical, well-typed, ordered record. Mirrors the CLI's type discipline.
    param([Parameter(Mandatory)] $In)

    $o = [ordered]@{}

    # Title -----------------------------------------------------------------
    $o['Title'] = ([string]$In.Title).Trim()

    # Rating: 1..5 or $null --------------------------------------------------
    $rating = $null
    if ($null -ne $In.Rating -and "$($In.Rating)".Trim() -ne '') {
        $r = 0
        if ([int]::TryParse("$($In.Rating)", [ref]$r) -and $r -ge 1 -and $r -le 5) { $rating = $r }
    }
    $o['Rating'] = $rating

    # WatchDate: string[] of non-empty values, deduped + sorted -------------
    $dates = @()
    foreach ($d in @($In.WatchDate)) {
        $s = ([string]$d).Trim()
        if ($s) { $dates += $s }
    }
    $o['WatchDate'] = @($dates | Sort-Object -Unique)

    # Status: validated enum -------------------------------------------------
    $status = ([string]$In.Status).Trim()
    if ($status -notin $script:ValidStatus) {
        # Infer when missing/invalid: dates -> watched, else watched_no_date
        $status = if ($o['WatchDate'].Count -gt 0) { 'watched' } else { 'watched_no_date' }
    }
    $o['Status'] = $status

    # PriorWatch: $true / $false / $null ------------------------------------
    $prior = $null
    $pwRaw = $In.PriorWatch
    if ($pwRaw -is [bool]) {
        $prior = [bool]$pwRaw
    } elseif ($null -ne $pwRaw -and "$pwRaw".Trim() -ne '') {
        $t = "$pwRaw".Trim().ToLower()
        if ($t -in @('true','1','yes'))      { $prior = $true }
        elseif ($t -in @('false','0','no'))  { $prior = $false }
    }
    # watched_no_date inherently implies a prior viewing (matches CLI semantics)
    if ($status -eq 'watched_no_date' -and $null -eq $prior) { $prior = $true }
    $o['PriorWatch'] = $prior

    # Remaining free-text fields --------------------------------------------
    $o['ReleaseDate'] = ([string]$In.ReleaseDate).Trim()
    $o['Runtime']     = ([string]$In.Runtime).Trim()
    $o['Genre']       = ([string]$In.Genre).Trim()
    $o['Director']    = ([string]$In.Director).Trim()
    $o['Studio']      = ([string]$In.Studio).Trim()
    $o['Actors']      = ([string]$In.Actors).Trim()
    $o['Notes']       = [string]$In.Notes   # preserve internal formatting/newlines

    return [PSCustomObject]$o
}

function Save-Records {
    # Persist a list of records back to movies.json, re-emitting in canonical order and
    # preserving the _metadata reference block.
    param([Parameter(Mandatory)] $Records)

    $db = Read-Db
    $ordered = foreach ($r in @($Records)) { ConvertTo-CanonicalRecord $r }
    $db.log = [object[]]$ordered
    $db | ConvertTo-Json -Depth 12 | Set-Content -Path $script:DbPath -Encoding UTF8
}

# --- Poster cache + iTunes ---------------------------------------------------------------------

function Get-PosterCache {
    if (Test-Path $script:PosterDb) {
        try { return (Get-Content -Raw -Path $script:PosterDb | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{}
}

function Set-PosterCacheEntry {
    param([string]$Key, [string]$Url)
    $cache = Get-PosterCache
    if ($cache.PSObject.Properties[$Key]) { $cache.$Key = $Url }
    else { $cache | Add-Member -NotePropertyName $Key -NotePropertyValue $Url }
    $cache | ConvertTo-Json -Depth 5 | Set-Content -Path $script:PosterDb -Encoding UTF8
}

function Resize-Artwork {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    # Upgrade the iTunes thumbnail (e.g. .../100x100bb.jpg) to a crisp poster.
    return ($Url -replace '\d+x\d+bb', '600x600bb')
}

function Invoke-ITunesSearch {
    param([string]$Term, [int]$Limit = 8, [switch]$Force)
    # Respect the circuit breaker for automatic lookups; -Force (explicit user action) bypasses it.
    if (-not $Force -and $script:ITunesDownUntil -and (Get-Date) -lt $script:ITunesDownUntil) { return @() }
    $uri = "https://itunes.apple.com/search?term=$([uri]::EscapeDataString($Term))&country=US&entity=movie&limit=$Limit"
    try {
        $res = Invoke-RestMethod -Uri $uri -TimeoutSec 5
        $script:ITunesDownUntil = $null   # success closes the breaker
    } catch {
        $script:ITunesDownUntil = (Get-Date).AddMinutes(2)   # trip the breaker on failure
        throw
    }
    $out = @()
    if ($res.resultCount -gt 0) {
        foreach ($m in $res.results) {
            $year = if ($m.releaseDate) { $m.releaseDate.Substring(0,4) } else { '' }
            $rt = ''
            if ($m.trackTimeMillis) {
                $ts = [TimeSpan]::FromMilliseconds($m.trackTimeMillis)
                $rt = '{0:hh\:mm\:ss}' -f $ts
            }
            $out += [PSCustomObject]@{
                title       = [string]$m.trackName
                year        = $year
                releaseDate = if ($m.releaseDate) { $m.releaseDate.Substring(0,10) } else { '' }
                runtime     = $rt
                genre       = [string]$m.primaryGenreName
                director    = if ($m.directorName) { [string]$m.directorName } else { [string]$m.artistName }
                poster      = Resize-Artwork $m.artworkUrl100
                notes       = [string]$m.longDescription
            }
        }
    }
    return $out
}

# --- HTTP plumbing -----------------------------------------------------------------------------

$script:Mime = @{
    '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8'
    '.js'='text/javascript; charset=utf-8'; '.json'='application/json; charset=utf-8'
    '.svg'='image/svg+xml'; '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'
    '.gif'='image/gif'; '.ico'='image/x-icon'; '.woff'='font/woff'; '.woff2'='font/woff2'
    '.webmanifest'='application/manifest+json'; '.map'='application/json'
}

function Write-Response {
    param($Context, [byte[]]$Bytes, [string]$ContentType = 'application/octet-stream', [int]$Status = 200)
    $resp = $Context.Response
    $resp.StatusCode = $Status
    $resp.ContentType = $ContentType
    $resp.Headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    $resp.ContentLength64 = $Bytes.Length
    $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $resp.OutputStream.Close()
}

function Write-Json {
    param($Context, $Object, [int]$Status = 200)
    $json = if ($null -eq $Object) { 'null' } else { $Object | ConvertTo-Json -Depth 12 -Compress }
    if ([string]::IsNullOrEmpty($json)) { $json = 'null' }
    Write-Response $Context ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Status
}

function Write-TextResponse {
    param($Context, [string]$Text, [string]$ContentType, [int]$Status = 200)
    Write-Response $Context ([Text.Encoding]::UTF8.GetBytes($Text)) $ContentType $Status
}

function Read-Body {
    param($Context)
    $reader = [IO.StreamReader]::new($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $raw = $reader.ReadToEnd(); $reader.Close()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Send-StaticFile {
    param($Context, [string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath) -or $RelPath -eq '/') { $RelPath = '/index.html' }
    $rel = $RelPath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $script:WebRoot $rel))
    # Path-traversal guard: resolved path must stay within the web root.
    if (-not $full.StartsWith([IO.Path]::GetFullPath($script:WebRoot), [StringComparison]::OrdinalIgnoreCase)) {
        Write-TextResponse $Context 'Forbidden' 'text/plain' 403; return
    }
    if (-not (Test-Path $full -PathType Leaf)) {
        Write-TextResponse $Context 'Not found' 'text/plain' 404; return
    }
    $ext = [IO.Path]::GetExtension($full).ToLower()
    $ct = if ($script:Mime.ContainsKey($ext)) { $script:Mime[$ext] } else { 'application/octet-stream' }
    Write-Response $Context ([IO.File]::ReadAllBytes($full)) $ct 200
}

# --- API router --------------------------------------------------------------------------------

function Invoke-Api {
    param($Context, [string]$Method, [string]$Path)

    # GET /api/db --------------------------------------------------------------
    if ($Method -eq 'GET' -and $Path -eq '/api/db') {
        Write-Json $Context (Read-Db); return
    }

    # POST /api/movies  (append) ----------------------------------------------
    if ($Method -eq 'POST' -and $Path -eq '/api/movies') {
        $body = Read-Body $Context
        if (-not $body -or [string]::IsNullOrWhiteSpace([string]$body.Title)) {
            Write-Json $Context @{ error = 'Title is required.' } 400; return
        }
        $db = Read-Db
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @($db.log)) { $records.Add($r) }
        $records.Add((ConvertTo-CanonicalRecord $body))
        Save-Records $records
        Write-Json $Context (Read-Db); return
    }

    # PUT/DELETE /api/movies/{index} ------------------------------------------
    if ($Path -match '^/api/movies/(\d+)$') {
        $idx = [int]$Matches[1]
        $db = Read-Db
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @($db.log)) { $records.Add($r) }
        if ($idx -lt 0 -or $idx -ge $records.Count) {
            Write-Json $Context @{ error = 'Record index out of range.' } 404; return
        }
        if ($Method -eq 'PUT') {
            $body = Read-Body $Context
            if (-not $body -or [string]::IsNullOrWhiteSpace([string]$body.Title)) {
                Write-Json $Context @{ error = 'Title is required.' } 400; return
            }
            $records[$idx] = ConvertTo-CanonicalRecord $body
            Save-Records $records
            Write-Json $Context (Read-Db); return
        }
        if ($Method -eq 'DELETE') {
            $records.RemoveAt($idx)
            Save-Records $records
            Write-Json $Context (Read-Db); return
        }
    }

    # GET /api/itunes?term=... -------------------------------------------------
    if ($Method -eq 'GET' -and $Path -eq '/api/itunes') {
        $term = $Context.Request.QueryString['term']
        if ([string]::IsNullOrWhiteSpace($term)) { Write-Json $Context @() ; return }
        # Explicit user action -> bypass the breaker and actually try the network.
        try { Write-Json $Context @(Invoke-ITunesSearch $term -Force) }
        catch { Write-Json $Context @{ error = "iTunes lookup failed: $($_.Exception.Message)" } 502 }
        return
    }

    # GET /api/poster?title=..&year=.. ----------------------------------------
    if ($Method -eq 'GET' -and $Path -eq '/api/poster') {
        $title = $Context.Request.QueryString['title']
        $year  = $Context.Request.QueryString['year']
        if ([string]::IsNullOrWhiteSpace($title)) { Write-Json $Context @{ url = $null }; return }
        $key = ("$title|$year").ToLower()
        $cache = Get-PosterCache
        if ($cache.PSObject.Properties[$key]) {
            Write-Json $Context @{ url = $cache.$key; cached = $true }; return
        }
        # Breaker open? Fast-fail without touching the network or persisting a (recoverable) miss.
        if ($script:ITunesDownUntil -and (Get-Date) -lt $script:ITunesDownUntil) {
            Write-Json $Context @{ url = $null; offline = $true }; return
        }
        $url = $null
        try {
            $term = if ($year) { "$title $year" } else { $title }
            $results = Invoke-ITunesSearch $term 5
            if ($results.Count -gt 0) {
                # Prefer an exact-ish title + matching year when possible.
                $best = $results | Where-Object { $_.poster } | Select-Object -First 1
                if ($year) {
                    $ym = $results | Where-Object { $_.poster -and $_.year -eq $year } | Select-Object -First 1
                    if ($ym) { $best = $ym }
                }
                if ($best) { $url = $best.poster }
            }
        } catch { }
        # Persist only real hits, so posters survive restarts but a transient outage doesn't
        # permanently blank a title.
        if ($url) { Set-PosterCacheEntry $key $url }
        Write-Json $Context @{ url = $url; cached = $false }; return
    }

    # GET /api/export/llm  (mirrors Copy-MovieDbToClipboard) ------------------
    if ($Method -eq 'GET' -and $Path -eq '/api/export/llm') {
        $db = Read-Db
        $dataOnly = $Context.Request.QueryString['dataOnly'] -eq '1'
        $min = $db.log | Select-Object Title, ReleaseDate, WatchDate, Status, PriorWatch, Rating, Notes
        if ($dataOnly) {
            $payload = $min
        } else {
            $payload = [PSCustomObject]@{ _metadata = $db._metadata; log = $min }
        }
        $text = $payload | ConvertTo-Json -Depth 12
        Write-Json $Context @{ text = $text; count = @($min).Count }; return
    }

    # POST /api/shutdown -------------------------------------------------------
    if ($Method -eq 'POST' -and $Path -eq '/api/shutdown') {
        Write-Json $Context @{ ok = $true; message = 'Projection room closing.' }
        $script:Running = $false; return
    }

    Write-Json $Context @{ error = "No route for $Method $Path" } 404
}

# --- Request dispatch --------------------------------------------------------------------------

function Invoke-Request {
    param($Context)
    $method = $Context.Request.HttpMethod
    $path   = $Context.Request.Url.AbsolutePath
    try {
        if ($path.StartsWith('/api/')) { Invoke-Api $Context $method $path }
        else { Send-StaticFile $Context $path }
    } catch {
        try { Write-Json $Context @{ error = $_.Exception.Message } 500 } catch { }
    }
}

# --- Server bootstrap --------------------------------------------------------------------------

function Start-MovieServer {
    param([int]$StartPort)

    $listener = [System.Net.HttpListener]::new()
    $chosen = $null
    foreach ($p in $StartPort..($StartPort + 20)) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://localhost:$p/")
            $listener.Start()
            $chosen = $p; break
        } catch {
            try { $listener.Close() } catch { }
            $listener = [System.Net.HttpListener]::new()
        }
    }
    if (-not $chosen) { throw "Could not bind any port in range $StartPort..$($StartPort + 20)." }

    $url = "http://localhost:$chosen/"
    $count = 0
    try { $count = @((Read-Db).log).Count } catch { }

    Write-Host ''
    Write-Host '  ┌──────────────────────────────────────────────┐' -ForegroundColor DarkYellow
    Write-Host '  │   THE PROJECTION ROOM  ·  now showing        │' -ForegroundColor Yellow
    Write-Host '  └──────────────────────────────────────────────┘' -ForegroundColor DarkYellow
    Write-Host "   $count titles in the archive" -ForegroundColor DarkGray
    Write-Host "   Open:  " -NoNewline -ForegroundColor Gray; Write-Host $url -ForegroundColor Cyan
    Write-Host "   Stop:  Ctrl+C in this window (or 'Close' in the app)`n" -ForegroundColor DarkGray

    if (-not $NoBrowser) {
        Write-Host "   Opening your browser..." -ForegroundColor DarkGray
        try {
            Start-Process $url
        } catch {
            # Fallback for unusual default-browser setups
            try { Start-Process 'explorer.exe' $url } catch {
                Write-Host "   (Couldn't auto-open a browser — paste the address above.)" -ForegroundColor DarkYellow
            }
        }
    }

    $script:Running = $true
    try {
        while ($script:Running -and $listener.IsListening) {
            # Use async so Ctrl+C can interrupt the polling sleep rather than
            # being swallowed by the blocking GetContext() .NET call.
            $task = $listener.GetContextAsync()
            while (-not $task.IsCompleted) {
                Start-Sleep -Milliseconds 200
                if (-not $script:Running) { break }
            }
            if (-not $script:Running -or -not $listener.IsListening) { break }
            if ($task.IsFaulted) { break }
            Invoke-Request $task.Result
        }
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
        Write-Host "`n  Projection room closed.`n" -ForegroundColor DarkYellow
    }
}

# Smoke-test hook: validate data layer + routing wiring without opening a socket.
if ($env:MT_WEB_TEST) {
    $db = Read-Db
    $rec = ConvertTo-CanonicalRecord ([PSCustomObject]@{ Title='__smoke__'; Rating='5'; WatchDate=@('2025-01-01'); Status='watched'; PriorWatch=$false })
    Write-Host "Data layer OK. $((@($db.log)).Count) records. Sample canonical record:"
    $rec | ConvertTo-Json -Depth 5 | Write-Host
    return
}

Start-MovieServer -StartPort $Port
