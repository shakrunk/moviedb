<#
.SYNOPSIS
    Seeds the movies.json database with the user's historical viewing log.
#>

if (-not (Get-Command Add-MovieEntry -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "MovieTracker.ps1")
}

$SeedData = @(
    @{ Title = "Inception"; Rating = 5; ReleaseDate = "7/15/2010"; Runtime = "2:28:00"; Genre = "Action, Science Fiction, Adventure"; Director = "Christopher Nolan"; Studio = "Legendary Pictures"; Actors = "Leonardo DiCaprio, Joseph Gordon-Levitt, Ken Watanabe, Tom Hardy, Elliot Page"; Notes = "Mind-bending and visually stunning." }
    @{ Title = "Pulp Fiction"; Rating = 1; ReleaseDate = "9/10/1994"; Runtime = "2:34:00"; Genre = "Thriller, Crime, Comedy"; Director = "Quentin Tarantino"; Studio = "Miramax"; Actors = "John Travolta, Samuel L. Jackson, Uma Thurman, Bruce Willis, Ving Rhames"; Notes = "Guess I'm not really a Tarantino fan :/" }
    @{ Title = "The Shawshank Redemption"; Rating = 5; ReleaseDate = "9/23/1994"; Runtime = "2:22:00"; Genre = "Drama, Crime"; Director = "Frank Darabont"; Studio = "Castle Rock Entertainment"; Actors = "Tim Robbins, Morgan Freeman, Bob Gunton, William Sadler, Clancy Brown"; Notes = "Uplifting and emotionally resonant." }
    @{ Title = "The Dark Knight"; Rating = 5; ReleaseDate = "7/16/2008"; Runtime = "2:32:00"; Genre = "Action, Crime, Thriller"; Director = "Christopher Nolan"; Studio = "Warner Bros. Pictures"; Actors = "Christian Bale, Heath Ledger, Aaron Eckhart, Michael Caine, Maggie Gyllenhaal"; Notes = "A superhero masterpiece." }
    @{ Title = "Forrest Gump"; Rating = 2; ReleaseDate = "6/23/1994"; Runtime = "2:22:00"; Genre = "Comedy, Drama, Romance"; Director = "Robert Zemeckis"; Studio = "Paramount Pictures"; Actors = "Tom Hanks, Robin Wright, Gary Sinise, Sally Field, Mykelti Williamson"; Notes = "Heartwarming but a bit too sentimental for my taste.  Kinda lacks a traditional story stucture." }
    @{ Title = "Interstellar"; Rating = 3; ReleaseDate = "11/5/2014"; Genre = "Adventure, Drama, Science Fiction"; Director = "Christopher Nolan"; Notes = "Ambitious and thought-provoking." }
)

Write-Host "Starting database seeding operation..." -ForegroundColor Cyan

foreach ($Item in $SeedData) {
    $Params = @{ Title = $Item.Title }
    if ($Item.ContainsKey('Rating'))      { $Params['Rating'] = $Item.Rating }
    if ($Item.ContainsKey('WatchDate'))   { $Params['WatchDate'] = $Item.WatchDate }
    if ($Item.ContainsKey('ReleaseDate')) { $Params['ReleaseDate'] = $Item.ReleaseDate }
    if ($Item.ContainsKey('Runtime'))     { $Params['Runtime'] = $Item.Runtime }
    if ($Item.ContainsKey('Genre'))       { $Params['Genre'] = $Item.Genre }
    if ($Item.ContainsKey('Director'))    { $Params['Director'] = $Item.Director }
    if ($Item.ContainsKey('Studio'))      { $Params['Studio'] = $Item.Studio }
    if ($Item.ContainsKey('Actors'))      { $Params['Actors'] = $Item.Actors }
    if ($Item.ContainsKey('Notes'))       { $Params['Notes'] = $Item.Notes }

    Add-MovieEntry @Params
}

Write-Host "Seeding execution finalized." -ForegroundColor Green