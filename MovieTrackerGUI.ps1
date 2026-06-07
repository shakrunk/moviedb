<#
.SYNOPSIS
    Graphical front-end for the movies.json data store.

.DESCRIPTION
    A native WPF window for browsing, searching, adding, editing, and deleting entries in the
    same movies.json database driven by MovieTracker.ps1. It reads and writes the identical file
    (preserving the embedded _metadata command reference and the canonical field order), so the
    GUI and the CLI stay perfectly in sync. No installs required beyond what ships with Windows.

    Launch by double-clicking, right-clicking -> "Run with PowerShell", or:
        powershell -ExecutionPolicy Bypass -File .\MovieTrackerGUI.ps1

    WPF requires a single-threaded apartment (STA). pwsh 7 runs MTA by default, so if we detect
    a non-STA apartment we relaunch ourselves under Windows PowerShell with -STA automatically.
#>

# --- STA bootstrap -----------------------------------------------------------------------------
# WPF's ShowDialog requires an STA thread. Relaunch under Windows PowerShell -STA if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$scriptPath`"")
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --- Data layer --------------------------------------------------------------------------------

$Global:MovieDbPath = Join-Path $PSScriptRoot "movies.json"

# Canonical record field order, matching MovieTracker.ps1's Add-MovieEntry output.
$script:FieldOrder = @('Title', 'Rating', 'WatchDate', 'ReleaseDate', 'Runtime', 'Genre', 'Director', 'Studio', 'Actors', 'Notes')

$script:Db      = $null   # the full parsed object (keeps _metadata)
$script:Records = $null   # List[object] of the raw record objects (source of truth)

function Load-Database {
    if (-not (Test-Path $Global:MovieDbPath)) {
        [System.Windows.MessageBox]::Show(
            "Database file not found at:`n$Global:MovieDbPath",
            "Movie Tracker", 'OK', 'Error') | Out-Null
        return $false
    }
    $script:Db = Get-Content -Raw -Path $Global:MovieDbPath | ConvertFrom-Json
    $script:Records = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($script:Db.log)) { $script:Records.Add($r) }
    return $true
}

function Save-Database {
    # Re-emit each record in the canonical field order, then write back preserving _metadata.
    $ordered = foreach ($r in $script:Records) {
        $o = [ordered]@{}
        foreach ($f in $script:FieldOrder) { $o[$f] = $r.$f }
        [PSCustomObject]$o
    }
    $script:Db.log = [object[]]$ordered
    $script:Db | ConvertTo-Json -Depth 10 | Set-Content -Path $Global:MovieDbPath -Encoding UTF8
}

function Get-Year ([object]$Record) {
    if ($Record.ReleaseDate -match '(\d{4})') { return $Matches[1] }
    return ''
}

function Get-Stars ([object]$Record) {
    $r = $Record.Rating
    if ($r) { return ([string][char]0x2605) * $r + ([string][char]0x2606) * (5 - $r) }
    return ''
}

# --- iTunes metadata lookup (mirrors the CLI's Add-MovieEntry behaviour) ------------------------

function Invoke-ITunesLookup ([string]$Title) {
    try {
        $uri = "https://itunes.apple.com/search?term=$([uri]::EscapeDataString($Title))&entity=movie&limit=8"
        $results = Invoke-RestMethod -Uri $uri -TimeoutSec 15
        if ($results.resultCount -gt 0) { return @($results.results) }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to query the iTunes API.`n$($_.Exception.Message)",
            "Metadata lookup", 'OK', 'Warning') | Out-Null
    }
    return @()
}

# --- Generic list chooser (used for iTunes results) --------------------------------------------

function Show-ListChooser ([string]$Title, [string]$Prompt, [string[]]$Items) {
    $win = [System.Windows.Window]@{
        Title = $Title; Width = 560; Height = 420
        WindowStartupLocation = 'CenterScreen'; ResizeMode = 'CanResizeWithGrip'
        Background = '#1E1E2E'
    }
    $grid = [System.Windows.Controls.Grid]@{ Margin = 12 }
    1..3 | ForEach-Object {
        $rd = [System.Windows.Controls.RowDefinition]::new()
        if ($_ -eq 2) { $rd.Height = [System.Windows.GridLength]::new(1, 'Star') }
        else { $rd.Height = 'Auto' }
        $grid.RowDefinitions.Add($rd)
    }
    $lbl = [System.Windows.Controls.TextBlock]@{ Text = $Prompt; Foreground = '#CDD6F4'; Margin = '0,0,0,8'; TextWrapping = 'Wrap' }
    [System.Windows.Controls.Grid]::SetRow($lbl, 0); $grid.Children.Add($lbl) | Out-Null

    $list = [System.Windows.Controls.ListBox]@{ Background = '#2A2A3C'; Foreground = '#CDD6F4'; BorderThickness = 0 }
    foreach ($i in $Items) { $list.Items.Add($i) | Out-Null }
    $list.SelectedIndex = 0
    [System.Windows.Controls.Grid]::SetRow($list, 1); $grid.Children.Add($list) | Out-Null

    $panel = [System.Windows.Controls.StackPanel]@{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right'; Margin = '0,10,0,0' }
    $ok = [System.Windows.Controls.Button]@{ Content = 'Use this'; Width = 90; Margin = '0,0,8,0'; IsDefault = $true }
    $cancel = [System.Windows.Controls.Button]@{ Content = 'Cancel'; Width = 90; IsCancel = $true }
    $panel.Children.Add($ok) | Out-Null; $panel.Children.Add($cancel) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($panel, 2); $grid.Children.Add($panel) | Out-Null

    $win.Content = $grid
    $script:chooserResult = -1
    $ok.Add_Click({ $script:chooserResult = $list.SelectedIndex; $win.DialogResult = $true }.GetNewClosure())
    $list.Add_MouseDoubleClick({ $script:chooserResult = $list.SelectedIndex; $win.DialogResult = $true }.GetNewClosure())
    $win.Owner = $script:MainWindow
    if ($win.ShowDialog()) { return $script:chooserResult }
    return -1
}

# --- Add / Edit editor window ------------------------------------------------------------------

$EditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Movie" Height="640" Width="560" WindowStartupLocation="CenterOwner"
        Background="#1E1E2E" ResizeMode="CanResize">
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#A6ADC8"/>
            <Setter Property="Margin" Value="0,8,0,2"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2A2A3C"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderBrush" Value="#45475A"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="CaretBrush" Value="#CDD6F4"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#45475A"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,6"/>
            <Setter Property="Margin" Value="6,0,0,0"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#2A2A3C"/>
            <Setter Property="Foreground" Value="#1E1E2E"/>
            <Setter Property="Padding" Value="6,4"/>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0">
            <TextBlock Text="Title" FontWeight="Bold" Foreground="#89B4FA"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="TitleBox" Grid.Column="0"/>
                <Button x:Name="FetchButton" Grid.Column="1" Content="Fetch metadata" Background="#89B4FA" Foreground="#1E1E2E"/>
            </Grid>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0">
            <StackPanel>
                <TextBlock Text="Rating"/>
                <ComboBox x:Name="RatingCombo"/>
                <TextBlock Text="Watch Date (YYYY-MM-DD)"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="WatchDateBox" Grid.Column="0"/>
                    <Button x:Name="TodayButton" Grid.Column="1" Content="Today"/>
                </Grid>
                <TextBlock Text="Release Date (YYYY-MM-DD)"/>
                <TextBox x:Name="ReleaseDateBox"/>
                <TextBlock Text="Runtime (HH:MM:SS)"/>
                <TextBox x:Name="RuntimeBox"/>
                <TextBlock Text="Genre"/>
                <TextBox x:Name="GenreBox"/>
                <TextBlock Text="Director"/>
                <TextBox x:Name="DirectorBox"/>
                <TextBlock Text="Studio"/>
                <TextBox x:Name="StudioBox"/>
                <TextBlock Text="Actors"/>
                <TextBox x:Name="ActorsBox"/>
                <TextBlock Text="Notes"/>
                <TextBox x:Name="NotesBox" AcceptsReturn="True" TextWrapping="Wrap" Height="70" VerticalScrollBarVisibility="Auto"/>
            </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="SaveButton" Content="Save" Background="#A6E3A1" Foreground="#1E1E2E" IsDefault="True"/>
            <Button x:Name="CancelButton" Content="Cancel" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

function Show-MovieEditor ([object]$Record) {
    # $Record = $null for a new entry; otherwise edits the passed record in place on Save.
    $reader = [System.Xml.XmlNodeReader]::new([xml]$EditorXaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    $win.Owner = $script:MainWindow
    $isNew = $null -eq $Record
    $win.Title = if ($isNew) { "Add Movie" } else { "Edit Movie" }

    $ctrl = {param($n) $win.FindName($n)}
    $ratingCombo = & $ctrl 'RatingCombo'
    @('Unrated', '1 - Terrible', '2 - Bad', '3 - Okay', '4 - Good', '5 - Masterpiece') |
        ForEach-Object { $ratingCombo.Items.Add($_) | Out-Null }
    $ratingCombo.SelectedIndex = 0

    if (-not $isNew) {
        (& $ctrl 'TitleBox').Text       = [string]$Record.Title
        (& $ctrl 'WatchDateBox').Text   = [string]$Record.WatchDate
        (& $ctrl 'ReleaseDateBox').Text = [string]$Record.ReleaseDate
        (& $ctrl 'RuntimeBox').Text     = [string]$Record.Runtime
        (& $ctrl 'GenreBox').Text       = [string]$Record.Genre
        (& $ctrl 'DirectorBox').Text    = [string]$Record.Director
        (& $ctrl 'StudioBox').Text      = [string]$Record.Studio
        (& $ctrl 'ActorsBox').Text      = [string]$Record.Actors
        (& $ctrl 'NotesBox').Text       = [string]$Record.Notes
        if ($Record.Rating) { $ratingCombo.SelectedIndex = [int]$Record.Rating }
    }

    (& $ctrl 'TodayButton').Add_Click({
        (& $ctrl 'WatchDateBox').Text = (Get-Date).ToString('yyyy-MM-dd')
    }.GetNewClosure())

    (& $ctrl 'FetchButton').Add_Click({
        $t = (& $ctrl 'TitleBox').Text
        if ([string]::IsNullOrWhiteSpace($t)) {
            [System.Windows.MessageBox]::Show("Enter a title first.", "Fetch metadata", 'OK', 'Information') | Out-Null
            return
        }
        $results = Invoke-ITunesLookup $t
        if ($results.Count -eq 0) {
            [System.Windows.MessageBox]::Show("No online results found for '$t'.", "Fetch metadata", 'OK', 'Information') | Out-Null
            return
        }
        $opts = foreach ($res in $results) {
            $y = if ($res.releaseDate) { $res.releaseDate.Substring(0,4) } else { 'Unknown' }
            "$($res.trackName) ($y) - $($res.directorName)"
        }
        $idx = Show-ListChooser "iTunes results" "Select the matching movie:" @($opts)
        if ($idx -lt 0) { return }
        $m = $results[$idx]
        if ($m.releaseDate)      { (& $ctrl 'ReleaseDateBox').Text = $m.releaseDate.Substring(0,10) }
        if ($m.primaryGenreName) { (& $ctrl 'GenreBox').Text = $m.primaryGenreName }
        if ($m.directorName)     { (& $ctrl 'DirectorBox').Text = $m.directorName }
        if ($m.trackTimeMillis)  {
            $ts = [TimeSpan]::FromMilliseconds($m.trackTimeMillis)
            (& $ctrl 'RuntimeBox').Text = '{0:hh\:mm\:ss}' -f $ts
        }
        if ([string]::IsNullOrWhiteSpace((& $ctrl 'TitleBox').Text) -and $m.trackName) {
            (& $ctrl 'TitleBox').Text = $m.trackName
        }
    }.GetNewClosure())

    (& $ctrl 'SaveButton').Add_Click({
        $title = (& $ctrl 'TitleBox').Text.Trim()
        if ([string]::IsNullOrWhiteSpace($title)) {
            [System.Windows.MessageBox]::Show("Title is required.", "Validation", 'OK', 'Warning') | Out-Null
            return
        }
        $rating = if ($ratingCombo.SelectedIndex -gt 0) { $ratingCombo.SelectedIndex } else { $null }

        if ($isNew) {
            $target = [PSCustomObject]@{}
            $script:Records.Add($target)
        } else {
            $target = $Record
        }
        # Assign in canonical order so re-created objects keep field ordering too.
        $vals = @{
            Title       = $title
            Rating      = $rating
            WatchDate   = (& $ctrl 'WatchDateBox').Text.Trim()
            ReleaseDate = (& $ctrl 'ReleaseDateBox').Text.Trim()
            Runtime     = (& $ctrl 'RuntimeBox').Text.Trim()
            Genre       = (& $ctrl 'GenreBox').Text.Trim()
            Director    = (& $ctrl 'DirectorBox').Text.Trim()
            Studio      = (& $ctrl 'StudioBox').Text.Trim()
            Actors      = (& $ctrl 'ActorsBox').Text.Trim()
            Notes       = (& $ctrl 'NotesBox').Text
        }
        foreach ($f in $script:FieldOrder) {
            if ($target.PSObject.Properties[$f]) { $target.$f = $vals[$f] }
            else { $target | Add-Member -NotePropertyName $f -NotePropertyValue $vals[$f] }
        }
        $win.DialogResult = $true
    }.GetNewClosure())

    return [bool]$win.ShowDialog()
}

# --- Main window -------------------------------------------------------------------------------

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Movie Tracker" Height="680" Width="1040"
        WindowStartupLocation="CenterScreen" Background="#1E1E2E">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#45475A"/>
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
    </Window.Resources>
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <DockPanel Grid.Row="0" Margin="0,0,0,12">
            <TextBlock Text="&#127909;  Movie Tracker" FontSize="22" FontWeight="Bold" Foreground="#89B4FA" VerticalAlignment="Center"/>
        </DockPanel>

        <!-- Toolbar -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid Grid.Column="0">
                <TextBox x:Name="SearchBox" Background="#2A2A3C" Foreground="#CDD6F4" BorderBrush="#45475A"
                         CaretBrush="#CDD6F4" Padding="8,6" FontSize="13" VerticalContentAlignment="Center"/>
                <TextBlock x:Name="SearchHint" Text="Search title, director, genre, actors, studio, notes..."
                           Foreground="#6C7086" Margin="10,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
            <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
                <Button x:Name="AddButton" Content="&#10133;  Add" Background="#A6E3A1" Foreground="#1E1E2E"/>
                <Button x:Name="EditButton" Content="&#9998;  Edit"/>
                <Button x:Name="DeleteButton" Content="&#128465;  Delete" Background="#F38BA8" Foreground="#1E1E2E"/>
                <Button x:Name="CopyButton" Content="&#128203;  Copy for LLM"/>
            </StackPanel>
        </Grid>

        <!-- Grid -->
        <DataGrid x:Name="MoviesGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True"
                  Background="#181825" Foreground="#CDD6F4" BorderBrush="#45475A" GridLinesVisibility="Horizontal"
                  HorizontalGridLinesBrush="#313244" RowBackground="#181825" AlternatingRowBackground="#1E1E2E"
                  HeadersVisibility="Column" SelectionMode="Single" CanUserAddRows="False" FontSize="13"
                  RowHeight="30">
            <DataGrid.Resources>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background" Value="#313244"/>
                    <Setter Property="Foreground" Value="#CDD6F4"/>
                    <Setter Property="Padding" Value="8,6"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                    <Setter Property="BorderThickness" Value="0"/>
                </Style>
                <Style TargetType="DataGridCell">
                    <Setter Property="BorderThickness" Value="0"/>
                    <Setter Property="Padding" Value="8,0"/>
                </Style>
            </DataGrid.Resources>
            <DataGrid.Columns>
                <DataGridTextColumn Header="Title" Binding="{Binding Title}" Width="2*"/>
                <DataGridTextColumn Header="Year" Binding="{Binding Year}" Width="60"/>
                <DataGridTextColumn Header="Rating" Binding="{Binding Stars}" Width="100"/>
                <DataGridTextColumn Header="Genre" Binding="{Binding Genre}" Width="2*"/>
                <DataGridTextColumn Header="Director" Binding="{Binding Director}" Width="1.5*"/>
                <DataGridTextColumn Header="Watched" Binding="{Binding WatchDate}" Width="100"/>
            </DataGrid.Columns>
        </DataGrid>

        <!-- Footer -->
        <TextBlock x:Name="StatusBar" Grid.Row="3" Foreground="#A6ADC8" Margin="2,10,0,0" FontSize="12"/>
    </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$MainXaml)
$script:MainWindow = [Windows.Markup.XamlReader]::Load($reader)

$SearchBox    = $script:MainWindow.FindName('SearchBox')
$SearchHint   = $script:MainWindow.FindName('SearchHint')
$MoviesGrid   = $script:MainWindow.FindName('MoviesGrid')
$StatusBar    = $script:MainWindow.FindName('StatusBar')
$AddButton    = $script:MainWindow.FindName('AddButton')
$EditButton   = $script:MainWindow.FindName('EditButton')
$DeleteButton = $script:MainWindow.FindName('DeleteButton')
$CopyButton   = $script:MainWindow.FindName('CopyButton')

function Build-DisplayRow ([object]$Record) {
    [PSCustomObject]@{
        Title     = $Record.Title
        Year      = Get-Year $Record
        Stars     = Get-Stars $Record
        Genre     = $Record.Genre
        Director  = $Record.Director
        WatchDate = $Record.WatchDate
        Record    = $Record   # hidden reference back to the raw record
    }
}

function Refresh-Grid {
    $term = $SearchBox.Text
    $matched = if ([string]::IsNullOrWhiteSpace($term)) {
        @($script:Records)
    } else {
        @($script:Records | Where-Object {
            $_.Title -match [regex]::Escape($term) -or
            $_.Director -match [regex]::Escape($term) -or
            $_.Genre -match [regex]::Escape($term) -or
            $_.Actors -match [regex]::Escape($term) -or
            $_.Studio -match [regex]::Escape($term) -or
            $_.Notes -match [regex]::Escape($term)
        })
    }

    $rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($r in $matched) { $rows.Add((Build-DisplayRow $r)) }
    $MoviesGrid.ItemsSource = $rows

    $rated = @($matched | Where-Object { $_.Rating })
    $status = "$($matched.Count) of $($script:Records.Count) " + $(if ($script:Records.Count -eq 1) { "entry" } else { "entries" })
    if ($rated.Count -gt 0) {
        $avg = [math]::Round(($rated | Measure-Object -Property Rating -Average).Average, 1)
        $status += "   |   avg rating $avg/5 across $($rated.Count) rated"
    }
    $unrated = @($matched | Where-Object { -not $_.Rating }).Count
    if ($unrated -gt 0) { $status += "   |   $unrated unrated" }
    $StatusBar.Text = $status
    $SearchHint.Visibility = if ([string]::IsNullOrEmpty($SearchBox.Text)) { 'Visible' } else { 'Collapsed' }
}

function Get-SelectedRecord {
    if ($MoviesGrid.SelectedItem) { return $MoviesGrid.SelectedItem.Record }
    return $null
}

# --- Wire up events ----------------------------------------------------------------------------

$SearchBox.Add_TextChanged({ Refresh-Grid })

$AddButton.Add_Click({
    if (Show-MovieEditor $null) {
        Save-Database
        Refresh-Grid
    }
})

$EditButton.Add_Click({
    $rec = Get-SelectedRecord
    if (-not $rec) {
        [System.Windows.MessageBox]::Show("Select a movie to edit.", "Edit", 'OK', 'Information') | Out-Null
        return
    }
    if (Show-MovieEditor $rec) {
        Save-Database
        Refresh-Grid
    }
})

$MoviesGrid.Add_MouseDoubleClick({
    $rec = Get-SelectedRecord
    if ($rec -and (Show-MovieEditor $rec)) {
        Save-Database
        Refresh-Grid
    }
})

$DeleteButton.Add_Click({
    $rec = Get-SelectedRecord
    if (-not $rec) {
        [System.Windows.MessageBox]::Show("Select a movie to delete.", "Delete", 'OK', 'Information') | Out-Null
        return
    }
    $answer = [System.Windows.MessageBox]::Show(
        "Permanently delete '$($rec.Title)' from the database?",
        "Confirm delete", 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        $script:Records.Remove($rec) | Out-Null
        Save-Database
        Refresh-Grid
    }
})

$CopyButton.Add_Click({
    # Mirror Copy-MovieDbToClipboard: minimized records + the embedded _metadata reference.
    $min = $script:Records | Select-Object Title, ReleaseDate, Rating, Notes
    $payload = [PSCustomObject]@{ _metadata = $script:Db._metadata; log = $min }
    $payload | ConvertTo-Json -Depth 10 | Set-Clipboard
    $StatusBar.Text = "Copied $($script:Records.Count) minimized records + LLM command reference to the clipboard."
})

# --- Launch ------------------------------------------------------------------------------------

if (Load-Database) {
    Refresh-Grid
    if ($env:MT_GUI_TEST) {
        # Smoke-test hook: build the editor window too, then exit without showing anything.
        [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new([xml]$EditorXaml)) | Out-Null
        Write-Host "GUI build OK ($($script:Records.Count) records loaded)."
    } else {
        $script:MainWindow.ShowDialog() | Out-Null
    }
}
