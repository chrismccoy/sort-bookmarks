#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

function Die([string]$msg) { [Console]::Error.WriteLine("Error: $msg"); exit 1 }

function Show-Usage {
    $n = if ($PSCommandPath) { Split-Path $PSCommandPath -Leaf } else { 'sort-bookmarks.ps1' }
    Write-Output @"
Usage: .\$n <command> [options]

Commands:
  urls          List unique URLs, sorted alphabetically (default: z-a)
  json          JSON objects with date, title, url (default: newest first)
  dated         Text output: date, name, url (default: newest first)
  folders       Text output: folder path, name, url (default: z-a)
  dupes         Show duplicate URLs with all bookmark entries grouped
  stats         Summary statistics about the bookmark collection
  check         Check each URL for HTTP reachability

Options:
  --asc                 Sort ascending (oldest first / a-z)
  --sort-by <field>     Sort field: date (default), title, url
                        For folders: also supports folder (default)
                        For dupes: also supports count (default) and url
  --browser <name>      Browser profile to use: chrome, brave, edge, chromium
  --profile <n>         Profile number (0=Default, 1=Profile 1, 2=Profile 2, ...)
  --folder <name>       Filter to bookmarks in folders matching this name
  --folder-exact        Require an exact folder name match (case-sensitive)
  --search <term>       Filter by title or URL substring (case-insensitive)
  --since <YYYY-MM-DD>  Only include bookmarks added on or after this date
  --before <YYYY-MM-DD> Only include bookmarks added on or before this date
  --limit <n>           Cap output to N results (N groups for dupes; N top folders for stats)
  --tsv                 Tab-separated, one record per line (all commands)
  --json                JSON object output (stats only)
  --color               Force color output even when not in a terminal
  --no-color            Disable color output
  -h, --help            Show this help message

Environment:
  BOOKMARKS     Override the bookmarks file path directly (bypasses --browser)
  NO_COLOR      Set to any value to disable colors (https://no-color.org/)

Notes:
  - json --tsv and dated --tsv produce identical output (both: date, title, url)
  - urls ignores --sort-by (always sorted alphabetically after dedup)
  - check uses curl.exe if available, otherwise Invoke-WebRequest

Examples:
  .\$n urls
  .\$n json
  .\$n dated
  .\$n folders --asc --tsv
  .\$n dupes
  .\$n stats
  .\$n check --limit 50
  `$env:BOOKMARKS = 'C:\path\to\Bookmarks'; .\$n urls
"@
}

function ConvertFrom-ChromeTimestamp([string]$ts) {
    $secs  = [long]$ts / 1e6 - 11644473600
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $epoch.AddSeconds($secs).ToLocalTime().ToString("MMMM dd, yyyy 'at' hh:mm tt")
}

function ConvertTo-ChromeTimestamp([string]$dateStr) {
    try {
        $d = [datetime]::ParseExact($dateStr, 'yyyy-MM-dd',
             [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { Die "Invalid date '$dateStr' — use YYYY-MM-DD format" }
    $epoch = [datetime]::new(1601, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    [long](($d.ToUniversalTime() - $epoch).Ticks / 10)
}

function Get-BookmarkEntries($node, [string]$path = '') {
    if ($node.type -eq 'url') {
        [PSCustomObject]@{
            folder     = $path
            name       = [string]$node.name
            url        = [string]$node.url
            date_added = [string]$node.date_added
        }
    } elseif ($null -ne $node.children) {
        $next = if ($path -eq '') { [string]$node.name } else { "$path/$([string]$node.name)" }
        foreach ($child in $node.children) { Get-BookmarkEntries $child $next }
    }
}

function Resolve-BookmarksPath([string]$browser, [string]$profileDir) {
    $base = $env:LOCALAPPDATA
    if (-not $base) { Die 'Could not locate %LOCALAPPDATA%' }
    switch ($browser.ToLower()) {
        'chrome'   { return Join-Path $base "Google\Chrome\User Data\$profileDir\Bookmarks" }
        'brave'    { return Join-Path $base "BraveSoftware\Brave-Browser\User Data\$profileDir\Bookmarks" }
        'edge'     { return Join-Path $base "Microsoft\Edge\User Data\$profileDir\Bookmarks" }
        'chromium' { return Join-Path $base "Chromium\User Data\$profileDir\Bookmarks" }
        default    { Die "Unknown browser '$browser'. Known: chrome, brave, edge, chromium" }
    }
}

function Sort-Entries($entries) {
    $desc = -not $script:Asc
    switch ($script:SortBy) {
        'title' { return $entries | Sort-Object { $_.name.ToLower() } -Descending:$desc }
        'url'   { return $entries | Sort-Object { $_.url.ToLower()  } -Descending:$desc }
        default { return $entries | Sort-Object { [long]$_.date_added } -Descending:$desc }
    }
}

$Cmd         = ''
$Asc         = $false
$Tsv         = $false
$JsonOutput  = $false
$Browser     = ''
$ProfileNum  = $null
$Folder      = ''
$FolderExact = $false
$Search      = ''
$Limit       = 0
$SortBy      = 'date'
$SinceDate   = ''
$BeforeDate  = ''
$ColorForced = $null

$argv = [System.Collections.Generic.List[string]]::new()
foreach ($a in $args) { $argv.Add([string]$a) }
$i = 0

while ($i -lt $argv.Count) {
    $a = $argv[$i]
    if     ($a -eq '-h' -or $a -eq '--help') { Show-Usage; exit 0 }
    elseif ($a -eq '--asc')          { $Asc = $true }
    elseif ($a -eq '--tsv')          { $Tsv = $true }
    elseif ($a -eq '--json')         { $JsonOutput = $true }
    elseif ($a -eq '--color')        { $ColorForced = $true }
    elseif ($a -eq '--no-color')     { $ColorForced = $false }
    elseif ($a -eq '--folder-exact') { $FolderExact = $true }
    elseif ($a -eq '--browser') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--browser requires a name (chrome, brave, edge, chromium)'
        }
        $Browser = $argv[$i]
    }
    elseif ($a -eq '--profile') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--profile requires a number (0=Default, 1=Profile 1, ...)'
        }
        if ($argv[$i] -notmatch '^\d+$') { Die '--profile must be a non-negative integer' }
        $ProfileNum = [int]$argv[$i]
    }
    elseif ($a -eq '--folder') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--folder requires a folder name'
        }
        $Folder = $argv[$i]
    }
    elseif ($a -eq '--search') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--search requires a search term'
        }
        $Search = $argv[$i]
    }
    elseif ($a -eq '--sort-by') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--sort-by requires a field: date, title, url, folder, count'
        }
        if ($argv[$i] -notin @('date','title','url','folder','count')) {
            Die '--sort-by must be one of: date, title, url (+ folder for folders; count for dupes)'
        }
        $SortBy = $argv[$i]
    }
    elseif ($a -eq '--since') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--since requires a date (YYYY-MM-DD)'
        }
        $SinceDate = $argv[$i]
    }
    elseif ($a -eq '--before') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--before requires a date (YYYY-MM-DD)'
        }
        $BeforeDate = $argv[$i]
    }
    elseif ($a -eq '--limit') {
        $i++
        if ($i -ge $argv.Count -or [string]::IsNullOrEmpty($argv[$i])) {
            Die '--limit requires a number'
        }
        if ($argv[$i] -notmatch '^\d+$') { Die '--limit must be a non-negative integer' }
        $Limit = [int]$argv[$i]
    }
    elseif ($a -like '-*') { Die "Unknown option '$a' — run with --help for usage" }
    else {
        if ($Cmd -ne '') { Die "Unexpected argument '$a' — only one command allowed" }
        $Cmd = $a
    }
    $i++
}

if ($Cmd -eq '') { Show-Usage; exit 0 }

$ProfileDir = if ($null -eq $ProfileNum -or $ProfileNum -eq 0) { 'Default' } `
              else { "Profile $ProfileNum" }

if ($null -ne $ProfileNum -and $Browser -eq '') {
    [Console]::Error.WriteLine("Note: --profile without --browser targets Chrome '$ProfileDir'")
}

[long]$SinceTs  = 0
[long]$BeforeTs = 0
if ($SinceDate  -ne '') { $SinceTs  = ConvertTo-ChromeTimestamp $SinceDate }
if ($BeforeDate -ne '') { $BeforeTs = ConvertTo-ChromeTimestamp $BeforeDate }
if ($SinceTs -gt 0 -and $BeforeTs -gt 0 -and $SinceTs -gt $BeforeTs) {
    Die "--since ($SinceDate) must not be later than --before ($BeforeDate)"
}

$BookmarksEnvSet = -not [string]::IsNullOrEmpty($env:BOOKMARKS)
$Bookmarks = if ($BookmarksEnvSet) { $env:BOOKMARKS } else { '' }

if ($Browser -ne '') {
    if ($BookmarksEnvSet) {
        [Console]::Error.WriteLine('Warning: --browser overrides the BOOKMARKS environment variable')
    }
    $Bookmarks = Resolve-BookmarksPath $Browser $ProfileDir
} elseif ($Bookmarks -eq '') {
    $Bookmarks = Resolve-BookmarksPath 'chrome' $ProfileDir
}

$UseColor = (-not [Console]::IsOutputRedirected) -and [string]::IsNullOrEmpty($env:NO_COLOR)
if ($null -ne $ColorForced) { $UseColor = [bool]$ColorForced }
if ($Tsv) { $UseColor = $false }

$E = [char]27
if ($UseColor) {
    $C_RESET  = "$E[0m";    $C_BOLD   = "$E[1m"
    $C_URL    = "$E[0;34m"; $C_FOLDER = "$E[0;32m"
    $C_DATE   = "$E[0;90m"; $C_COUNT  = "$E[1;33m"
    $C_OK     = "$E[0;32m"; $C_WARN   = "$E[0;33m"; $C_ERROR = "$E[0;31m"
} else {
    $C_RESET = ''; $C_BOLD = ''; $C_URL = ''; $C_FOLDER = ''
    $C_DATE  = ''; $C_COUNT = ''; $C_OK = ''; $C_WARN = ''; $C_ERROR = ''
}

if (-not (Test-Path -LiteralPath $Bookmarks -PathType Leaf)) {
    [Console]::Error.WriteLine("Error: Bookmarks file not found at: $Bookmarks")
    if ($Browser -ne '') {
        [Console]::Error.WriteLine("Is '$Browser' installed, and has profile '$ProfileDir' been created?")
    } else {
        [Console]::Error.WriteLine('Override with: $env:BOOKMARKS = "C:\path\to\Bookmarks"')
    }
    exit 1
}

try {
    $rawJson = Get-Content -LiteralPath $Bookmarks -Raw -Encoding UTF8
    $bmData  = $rawJson | ConvertFrom-Json
} catch {
    [Console]::Error.WriteLine("Error: Bookmarks file is not valid JSON: $Bookmarks")
    [Console]::Error.WriteLine('The browser may be writing to it. Close the browser or try again.')
    exit 1
}

if ($null -eq $bmData -or $null -eq $bmData.roots) {
    Die "File does not look like a Chrome Bookmarks file: $Bookmarks"
}

$allEntries = @(
    $bmData.roots.PSObject.Properties.Value |
    Where-Object { $_ -ne $null } |
    ForEach-Object { Get-BookmarkEntries $_ '' }
)

$filtered = $allEntries

if ($Folder -ne '') {
    if ($FolderExact) {
        $filtered = $filtered | Where-Object { $_.folder -ceq $Folder }
    } else {
        $filtered = $filtered | Where-Object {
            $_.folder.IndexOf($Folder, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    }
}
if ($Search -ne '') {
    $filtered = $filtered | Where-Object {
        $_.name.IndexOf($Search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.url.IndexOf($Search,  [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }
}
if ($SinceTs  -gt 0) { $filtered = $filtered | Where-Object { [long]$_.date_added -ge $SinceTs  } }
if ($BeforeTs -gt 0) { $filtered = $filtered | Where-Object { [long]$_.date_added -le $BeforeTs } }

$filtered = @($filtered)

switch ($Cmd) {

    'urls' {
        $urls = @($filtered | Select-Object -ExpandProperty url | Sort-Object -Unique)
        if (-not $Asc) { [array]::Reverse($urls) }
        if ($Limit -gt 0) { $urls = @($urls | Select-Object -First $Limit) }
        foreach ($u in $urls) { Write-Output "${C_URL}${u}${C_RESET}" }
    }

    'json' {
        $sorted = @(Sort-Entries $filtered)
        if ($Limit -gt 0) { $sorted = @($sorted | Select-Object -First $Limit) }
        foreach ($e in $sorted) {
            $entry = [PSCustomObject][ordered]@{
                date  = ConvertFrom-ChromeTimestamp $e.date_added
                title = $e.name
                url   = $e.url
            }
            if ($Tsv) {
                Write-Output "$($entry.date)`t$($entry.title)`t$($entry.url)"
            } else {
                $entry | ConvertTo-Json
            }
        }
    }

    'dated' {
        $sorted = @(Sort-Entries $filtered)
        if ($Limit -gt 0) { $sorted = @($sorted | Select-Object -First $Limit) }
        foreach ($e in $sorted) {
            $date = ConvertFrom-ChromeTimestamp $e.date_added
            if ($Tsv) {
                Write-Output "$date`t$($e.name)`t$($e.url)"
            } else {
                Write-Output "${C_DATE}${date}${C_RESET}"
                Write-Output $e.name
                Write-Output "${C_URL}$($e.url)${C_RESET}"
                Write-Output ''
            }
        }
    }

    'folders' {
        $desc = -not $Asc
        $sorted = if ($SortBy -eq 'date' -or $SortBy -eq 'folder') {
            @($filtered | Sort-Object { $_.folder.ToLower() }, { $_.name.ToLower() } -Descending:$desc)
        } else {
            @(Sort-Entries $filtered)
        }
        if ($Limit -gt 0) { $sorted = @($sorted | Select-Object -First $Limit) }
        foreach ($e in $sorted) {
            if ($Tsv) {
                Write-Output "$($e.folder)`t$($e.name)`t$($e.url)"
            } else {
                Write-Output "${C_FOLDER}$($e.folder)${C_RESET}"
                Write-Output ''
                Write-Output $e.name
                Write-Output ''
                Write-Output "${C_URL}$($e.url)${C_RESET}"
                Write-Output ''
            }
        }
    }

    'dupes' {
        $dupeObjects = @(
            $filtered |
            Group-Object url |
            Where-Object { $_.Count -gt 1 } |
            ForEach-Object {
                $g = $_
                $bookmarks = @(
                    $g.Group |
                    Sort-Object { [long]$_.date_added } |
                    ForEach-Object {
                        [PSCustomObject]@{
                            title  = $_.name
                            date   = ConvertFrom-ChromeTimestamp $_.date_added
                            folder = $_.folder
                        }
                    }
                )
                [PSCustomObject]@{ url = $g.Name; count = $g.Count; bookmarks = $bookmarks }
            }
        )

        $desc   = -not $Asc
        $sorted = if ($SortBy -eq 'url') {
            @($dupeObjects | Sort-Object { $_.url.ToLower() } -Descending:$desc)
        } else {
            @($dupeObjects | Sort-Object count -Descending:$desc)
        }
        if ($Limit -gt 0) { $sorted = @($sorted | Select-Object -First $Limit) }

        if ($Tsv) {
            foreach ($d in $sorted) {
                foreach ($b in $d.bookmarks) {
                    Write-Output "$($d.url)`t$($d.count)`t$($b.folder)`t$($b.date)`t$($b.title)"
                }
            }
        } else {
            foreach ($d in $sorted) {
                Write-Output "${C_COUNT}[$($d.count) copies]${C_RESET} ${C_URL}$($d.url)${C_RESET}"
                foreach ($b in $d.bookmarks) {
                    Write-Output "  ${C_FOLDER}$($b.folder)${C_RESET}  |  ${C_DATE}$($b.date)${C_RESET}  |  $($b.title)"
                }
                Write-Output ''
            }
            $redundant = ($sorted | ForEach-Object { $_.count - 1 } | Measure-Object -Sum).Sum
            [Console]::Error.WriteLine("---`n$($sorted.Count) duplicate URLs · $redundant redundant entries")
        }
    }

    'stats' {
        if ($JsonOutput -and $Tsv) { Die 'stats: --json and --tsv cannot be combined' }

        if ($filtered.Count -eq 0) {
            $noMsg = 'No bookmarks found'
            if ($Folder -ne '' -and $Search -ne '') {
                $noMsg += " matching folder `"$Folder`" and search `"$Search`""
            } elseif ($Folder -ne '') { $noMsg += " in folder `"$Folder`"" }
            elseif ($Search -ne '')   { $noMsg += " matching `"$Search`"" }

            if ($JsonOutput)  { [PSCustomObject]@{ error = $noMsg } | ConvertTo-Json }
            elseif ($Tsv)     { Write-Output "no_bookmarks_found`t1" }
            else              { Write-Output $noMsg }
        } else {
            $byDate     = @($filtered | Sort-Object { [long]$_.date_added })
            $oldest     = $byDate[0]
            $newest     = $byDate[-1]
            $allUrls    = @($filtered | Select-Object -ExpandProperty url)
            $uniqUrls   = @($allUrls | Sort-Object -Unique)
            $dupeCount  = $allUrls.Count - $uniqUrls.Count
            $folderCount = @($filtered | Select-Object -ExpandProperty folder | Sort-Object -Unique).Count
            $topN       = if ($Limit -gt 0) { $Limit } else { 5 }
            $topFolders = @(
                $filtered |
                Group-Object folder |
                Sort-Object Count -Descending |
                Select-Object -First $topN |
                ForEach-Object { [PSCustomObject]@{ folder = $_.Name; count = $_.Count } }
            )

            if ($Tsv) {
                Write-Output "total_bookmarks`t$($filtered.Count)"
                Write-Output "unique_urls`t$($uniqUrls.Count)"
                Write-Output "duplicate_urls`t$dupeCount"
                Write-Output "unique_folders`t$folderCount"
                Write-Output "oldest_date`t$(ConvertFrom-ChromeTimestamp $oldest.date_added)"
                Write-Output "oldest_title`t$($oldest.name)"
                Write-Output "newest_date`t$(ConvertFrom-ChromeTimestamp $newest.date_added)"
                Write-Output "newest_title`t$($newest.name)"
                foreach ($f in $topFolders) { Write-Output "top_folder`t$($f.folder)`t$($f.count)" }
            } elseif ($JsonOutput) {
                [PSCustomObject][ordered]@{
                    total_bookmarks      = $filtered.Count
                    unique_urls          = $uniqUrls.Count
                    duplicate_urls       = $dupeCount
                    unique_folders       = $folderCount
                    oldest               = [PSCustomObject]@{
                        title = $oldest.name
                        date  = ConvertFrom-ChromeTimestamp $oldest.date_added
                    }
                    newest               = [PSCustomObject]@{
                        title = $newest.name
                        date  = ConvertFrom-ChromeTimestamp $newest.date_added
                    }
                    top_folders_by_count = $topFolders
                } | ConvertTo-Json -Depth 5
            } else {
                $od = ConvertFrom-ChromeTimestamp $oldest.date_added
                $nd = ConvertFrom-ChromeTimestamp $newest.date_added
                Write-Output "${C_BOLD}Bookmarks${C_RESET}      ${C_COUNT}$($filtered.Count)${C_RESET}"
                Write-Output "${C_BOLD}Unique URLs${C_RESET}    ${C_COUNT}$($uniqUrls.Count)${C_RESET}  ($dupeCount duplicates)"
                Write-Output "${C_BOLD}Folders${C_RESET}        ${C_COUNT}${folderCount}${C_RESET}"
                Write-Output ''
                Write-Output "${C_BOLD}Oldest${C_RESET}  ${C_DATE}${od}${C_RESET}  $($oldest.name)"
                Write-Output "${C_BOLD}Newest${C_RESET}  ${C_DATE}${nd}${C_RESET}  $($newest.name)"
                Write-Output ''
                Write-Output "${C_BOLD}Top Folders${C_RESET}"
                foreach ($f in $topFolders) {
                    Write-Output "  ${C_FOLDER}$($f.folder)${C_RESET}  ${C_COUNT}$($f.count)${C_RESET}"
                }
            }
        }
    }

    'check' {
        $hasCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)

        $urls = @($filtered | Select-Object -ExpandProperty url | Sort-Object -Unique)
        if ($Limit -gt 0) { $urls = @($urls | Select-Object -First $Limit) }

        [int]$Checked = 0; [int]$Failed = 0; [int]$Redirected = 0; [int]$Errors = 0

        foreach ($url in $urls) {
            if ([string]::IsNullOrWhiteSpace($url)) { continue }

            if ($hasCurl) {
                $code = & curl.exe --silent --head --max-time 10 --output NUL `
                    --write-out '%{http_code}' -- $url 2>$null
                if ($LASTEXITCODE -ne 0 -and $code -notmatch '^\d{3}$') { $code = '000' }
                $code = $code.Trim()
            } else {
                try {
                    $iwrParams = @{
                        Uri                = $url
                        Method             = 'Head'
                        TimeoutSec         = 10
                        MaximumRedirection = 0
                        ErrorAction        = 'Stop'
                        UseBasicParsing    = $true
                    }
                    $resp = Invoke-WebRequest @iwrParams
                    $code = "$([int]$resp.StatusCode)"
                } catch {
                    $ex = $_.Exception
                    if ($ex -is [System.Net.WebException] -and $null -ne $ex.Response) {
                        $code = "$([int]([System.Net.HttpWebResponse]$ex.Response).StatusCode)"
                    } elseif ($null -ne $ex.Response) {
                        try   { $code = "$([int]$ex.Response.StatusCode)" }
                        catch { $code = '000' }
                    } else { $code = '000' }
                }
            }

            $Checked++

            if ($Tsv) {
                Write-Output "$code`t$url"
            } elseif ($code -match '^2\d\d$') {
                Write-Output "${C_OK}OK   ${C_RESET} $code  ${C_URL}${url}${C_RESET}"
            } elseif ($code -match '^3\d\d$') {
                Write-Output "${C_WARN}REDIR${C_RESET} $code  ${C_URL}${url}${C_RESET}"
                $Redirected++
            } elseif ($code -match '^[45]\d\d$') {
                Write-Output "${C_ERROR}FAIL ${C_RESET} $code  $url"
                $Failed++
            } else {
                Write-Output "${C_ERROR}ERR  ${C_RESET}        $url"
                $Errors++
            }
        }

        if (-not $Tsv) {
            [Console]::Error.WriteLine("---`n$Checked checked · $Failed unreachable · $Redirected redirected · $Errors errors")
        }
    }

    default {
        [Console]::Error.WriteLine("Error: Unknown command '$Cmd'")
        Show-Usage
        exit 1
    }
}
