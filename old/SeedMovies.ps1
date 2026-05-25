<#
.SYNOPSIS
    Seeds the movies.json database with the user's historical viewing log.
.DESCRIPTION
    Imports the MovieTracker module and sequentially populates the log array
    with predefined movie entries and structural metadata.
#>

# Ensure the parent environment functions are loaded
if (-not (Get-Command Add-MovieEntry -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "MovieTracker.ps1")
}

$SeedData = @(
    @{ Title = "Inception"; Rating = 5; ReleaseDate = "7/15/2010"; Genre = "Action, Science Fiction, Adventure"; Director = "Christopher Nolan"; Notes = "Mind-bending and visually stunning." }
    @{ Title = "Pulp Fiction"; Rating = 1; ReleaseDate = "9/10/1994"; Genre = "Thriller, Crime, Comedy"; Director = "Quentin Tarantino"; Notes = "Guess I'm not really a Tarantino fan :/" }
    @{ Title = "The Shawshank Redemption"; Rating = 5; ReleaseDate = "9/23/1994"; Genre = "Drama, Crime"; Director = "Frank Darabont"; Notes = "Uplifting and emotionally resonant." }
    @{ Title = "The Dark Knight"; Rating = 5; ReleaseDate = "7/16/2008"; Genre = "Action, Crime, Thriller"; Director = "Christopher Nolan"; Notes = "A superhero masterpiece." }
    @{ Title = "Forrest Gump"; Rating = 2; ReleaseDate = "6/23/1994"; Genre = "Comedy, Drama, Romance"; Director = "Robert Zemeckis"; Notes = "Heartwarming but a bit too sentimental." }
    @{ Title = "Interstellar"; Rating = 3; ReleaseDate = "11/5/2014"; Genre = "Adventure, Drama, Science Fiction"; Director = "Christopher Nolan"; Notes = "Ambitious and thought-provoking." }
    @{ Title = "GATTACA"; Rating = 5; ReleaseDate = "7/9/1997"; Genre = "Science Fiction, Drama, Thriller"; Director = "Andrew Niccol"; Notes = "" }
    @{ Title = "A Bugs Life"; Rating = 4; ReleaseDate = "11/25/1998"; Genre = "Adventure, Animation, Comedy, Family"; Director = "John Lasseter"; Notes = "" }
    @{ Title = "The Sixth Sense"; ReleaseDate = "8/6/1999"; Genre = "Thriller, Mystery"; Director = "M. Night Shyamalan"; Notes = "" }
    @{ Title = "The Matrix"; ReleaseDate = "3/31/1999"; Genre = "Science Fiction, Action"; Director = "The Wachowskis"; Notes = "" }
    @{ Title = "Looper"; ReleaseDate = "9/28/2012"; Genre = "Science Fiction, Action"; Director = "Rian Johnson"; Notes = "" }
    @{ Title = "Upgrade"; ReleaseDate = "6/1/2018"; Genre = "Science Fiction, Action"; Director = "Leigh Whannell"; Notes = "" }
    @{ Title = "Everything Everywhere All at Once"; ReleaseDate = "3/25/2022"; Genre = "Science Fiction, Adventure"; Director = "Daniel Kwan, Daniel Scheinert"; Notes = "" }
    @{ Title = "Ex Machina"; ReleaseDate = "4/10/2015"; Genre = "Science Fiction, Thriller"; Director = "Alex Garland"; Notes = "" }
    @{ Title = "Arrival"; ReleaseDate = "11/11/2016"; Genre = "Science Fiction, Drama"; Director = "Denis Villeneuve"; Notes = "" }
    @{ Title = "Coherence"; ReleaseDate = "9/19/2013"; Genre = "Science Fiction, Thriller"; Director = "James Ward Byrkit"; Notes = "" }
    @{ Title = "Triangle"; ReleaseDate = "10/16/2009"; Genre = "Thriller, Mystery"; Director = "Christopher Smith"; Notes = "" }
    @{ Title = "Predestination"; ReleaseDate = "8/28/2014"; Genre = "Science Fiction, Thriller"; Director = "The Spierig Brothers"; Notes = "" }
    @{ Title = "Fall"; ReleaseDate = "8/12/2022"; Genre = "Thriller, Survival"; Director = "Scott Mann"; Notes = "" }
    @{ Title = "Searching"; ReleaseDate = "8/24/2018"; Genre = "Thriller, Mystery"; Director = "Aneesh Chaganty"; Notes = "" }
    @{ Title = "Heretic"; ReleaseDate = "11/8/2024"; Genre = "Horror, Thriller"; Director = "Scott Beck, Bryan Woods"; Notes = "" }
    @{ Title = "The Housemaid"; ReleaseDate = "5/13/2010"; Genre = "Thriller, Drama"; Director = "Im Sang-soo"; Notes = "" }
    @{ Title = "Subservience"; ReleaseDate = "8/23/2024"; Genre = "Science Fiction, Thriller"; Director = "S.K. Dale"; Notes = "" }
)

Write-Host "Starting database seeding operation..." -ForegroundColor Cyan

foreach ($Item in $SeedData) {
    $Params = @{ Title = $Item.Title }
    if ($Item.ContainsKey('Rating'))      { $Params['Rating'] = $Item.Rating }
    if ($Item.ContainsKey('ReleaseDate')) { $Params['ReleaseDate'] = $Item.ReleaseDate }
    if ($Item.ContainsKey('Genre'))       { $Params['Genre'] = $Item.Genre }
    if ($Item.ContainsKey('Director'))    { $Params['Director'] = $Item.Director }
    if ($Item.ContainsKey('Notes'))       { $Params['Notes'] = $Item.Notes }

    Add-MovieEntry @Params
}

Write-Host "Seeding execution finalized." -ForegroundColor Green
