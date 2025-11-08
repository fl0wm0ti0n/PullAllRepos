[CmdletBinding()]
param(
  # Zielstruktur: GitRepo\<Kategorie>\<Repo>
  [string]$Root = (Join-Path $HOME 'Documents\GitRepo'),

  # GitHub-Owner (User oder Org). Wenn leer und -Mode enthaelt Clone -> automatisch ermitteln.
  [string]$Owner,

  # Arbeitsmodus: Clone = nur fehlende Repos klonen, Pull = nur lokale Repos updaten, Both = beides
  [ValidateSet('Clone','Pull','Both')][string]$Mode = 'Both',

  # Pull-Optionen
  [switch]$ReportOnly,
  [switch]$AutoStash,
  [switch]$NoRebase,
  [switch]$NoFetch,
  [switch]$PullOnlyChanged,

  # Remote-Quellen (nur fuer Clone)
  [switch]$UseGh,                 # GitHub CLI bevorzugen, wenn vorhanden
  [switch]$UseHttps,              # statt SSH die HTTPS-URL verwenden
  [switch]$IncludeForks,          # Forks NICHT ausfiltern
  [switch]$IncludeArchived,       # Archived NICHT ausfiltern
  [switch]$CategorizeByLanguage,  # Kategorie = primaryLanguage
  [switch]$CategorizeByTopic,     # Kategorie = erstes Topic (Vorrang vor Language)

  # Hilfe/Syntax
  [switch]$ShowSyntax,
  [Alias('Help','?')][switch]$ShowHelp
)

$ErrorActionPreference = 'Stop'

function Show-Usage([string]$Reason = $null) {
  if ($Reason) { Write-Host "`n[Fehler] $Reason" -ForegroundColor Red }
  $lines = @(
    "================= Hilfe / Syntax =================",
    "Aufruf:",
    "  .\PullAll.ps1 [-Root <Pfad>] [-Owner <user|org>] [-Mode Clone|Pull|Both]",
    "                [-ReportOnly] [-AutoStash] [-NoRebase] [-NoFetch] [-PullOnlyChanged]",
    "                [-UseGh] [-UseHttps] [-IncludeForks] [-IncludeArchived]",
    "                [-CategorizeByTopic] [-CategorizeByLanguage] [-ShowSyntax] [-ShowHelp]",
    "",
    "Beispiele:",
    "  .\PullAll.ps1 -Mode Pull                         # nur lokale Repos updaten",
    "  .\PullAll.ps1 -Mode Clone -CategorizeByTopic     # fehlende Repos nach Topic einsortieren",
    "  .\PullAll.ps1 -Owner meineOrg -Mode Both         # Org klonen + alles pullen",
    "  .\PullAll.ps1 -Mode Pull -PullOnlyChanged        # nur wenn behind > 0",
    "",
    "Legende (git status --porcelain):",
    "  XY vor dem Pfad: X = Index (staged), Y = Working Tree (unstaged)",
    "  M=Modified, A=Added, D=Deleted, R=Renamed, C=Copied, ??=Untracked, !!=Ignored",
    "  Beispiele: ' M file' (geaendert, nicht gestaged) | 'M  file' (gestaged) | '?? file' (untracked)",
    "",
    "Upstream-Status:",
    "  ahead N = lokal N Commits mehr (nicht gepusht)",
    "  behind N = Remote N Commits voraus (lokal aelter)",
    "  beides >0 = divergiert",
    "",
    "Nuetzliche Befehle:",
    "  git add <datei> | git restore <datei> | git restore --staged <datei>",
    "  git branch --set-upstream-to origin/<branch>",
    "=================================================="
  )
  Write-Host ($lines -join "`n")
}

function Header($t){ Write-Host "`n======== $t ========" -ForegroundColor Cyan }
function Require-Git { if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git nicht gefunden (git.exe nicht im PATH)." } }
function HasGh { return [bool](Get-Command gh -ErrorAction SilentlyContinue) }
function Show-SyntaxInfo { Header "Syntax-Info"; Show-Usage }

function Get-DefaultOwner {
  if (HasGh) {
    try { $me = gh api user -q .login 2>$null; if ($me) { return $me.Trim() } } catch {}
  }
  $token = $Env:GITHUB_TOKEN
  if ($token) {
    try {
      $headers = @{ "Accept"="application/vnd.github+json"; "Authorization"="Bearer $token" }
      $me = Invoke-RestMethod -Method GET -Uri "https://api.github.com/user" -Headers $headers
      if ($me.login) { return $me.login }
    } catch {}
  }
  return $null
}

function Get-BranchInfo($repoPath){
  $branch = (git -C $repoPath rev-parse --abbrev-ref HEAD 2>$null).Trim()
  if (-not $branch) { return @{ Branch='(detached HEAD)'; Upstream=$null; Ahead=0; Behind=0 } }
  $upstream = (git -C $repoPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null).Trim()
  $ahead = 0; $behind = 0
  if ($upstream){
    $range = "HEAD...@{u}"
    $counts = (git -C $repoPath rev-list --left-right --count $range 2>$null).Trim() -split '\s+'
    if ($counts.Count -eq 2){ $ahead = [int]$counts[0]; $behind = [int]$counts[1] }
  }
  return @{ Branch=$branch; Upstream=$upstream; Ahead=$ahead; Behind=$behind }
}

function Show-DirtyDetails($repo){
  $lines = git -C $repo status --porcelain -uall
  if (-not $lines){ return $false }
  Write-Host " Working tree: DIRTY" -ForegroundColor Yellow
  foreach($l in $lines){ Write-Host "  $l" }
  return $true
}

function Pull-ExistingRepo($repoPath){
  $name = Split-Path $repoPath -Leaf
  Header "$name (pull)"
  if (-not $NoFetch){ git -C $repoPath fetch --all --prune | Out-Null }
  $info = Get-BranchInfo $repoPath
  $up = $(if ($info.Upstream){ $info.Upstream } else { "(kein Upstream gesetzt)" })
  Write-Host (" Branch:   {0}" -f $info.Branch)
  Write-Host (" Upstream: {0}" -f $up)
  if ($info.Upstream){
    $col = $(if ($info.Behind -gt 0){'Yellow'} elseif($info.Ahead -gt 0){'DarkGray'} else {'Green'})
    Write-Host (" Status:   ahead {0} / behind {1}" -f $info.Ahead, $info.Behind) -ForegroundColor $col
  }
  $dirty = Show-DirtyDetails $repoPath
  if ($ReportOnly){ return }

  if ($PullOnlyChanged -and $info.Upstream -and $info.Behind -le 0){
    Write-Host " Uebersprungen (nicht behind)." -ForegroundColor DarkGray
    return
  }

  if ($dirty -and -not $AutoStash){
    Write-Host " Uebersprungen (dirty). Nutze -AutoStash zum automatischen Stashen." -ForegroundColor Yellow
    return
  }

  $didStash = $false
  if ($dirty -and $AutoStash){
    $msg = "auto-$(Get-Date -Format 'yyyy-MM-ddTHH-mm-ss')"
    git -C $repoPath stash push -u -m $msg | Out-Null
    $didStash = $true
    Write-Host " Auto-gestasht: $msg" -ForegroundColor DarkGray
  }

  $args = @('--all','--prune')
  if ($NoRebase){ $args = @('--ff-only') + $args } else { $args = @('--rebase','--autostash') + $args }
  $out = git -C $repoPath pull @args 2>&1
  Write-Host $out

  if ($didStash){
    $pop = git -C $repoPath stash pop 2>&1
    if ($LASTEXITCODE -ne 0){
      Write-Host " Konflikte beim stash pop - bitte manuell loesen." -ForegroundColor Red
      Write-Host $pop
    } else {
      Write-Host " Stash wieder eingespielt." -ForegroundColor DarkGray
    }
  }
}

function Ensure-Cloned($root, $category, $name, $url){
  $catDir = Join-Path $root $category
  $dest   = Join-Path $catDir $name
  if (-not (Test-Path -LiteralPath $catDir)) { New-Item -ItemType Directory -Path $catDir | Out-Null }

  if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
    Write-Host "Repo vorhanden: $dest" -ForegroundColor DarkGray
    return $dest
  }
  if (Test-Path -LiteralPath $dest -and -not (Test-Path -LiteralPath (Join-Path $dest '.git'))) {
    Write-Host "WARNUNG: Ziel existiert, ist aber kein Git-Repo: $dest" -ForegroundColor Yellow
    return $null
  }

  Header "$name (clone)"
  Write-Host " Ziel: $dest"
  Write-Host " URL:  $url"
  if ($ReportOnly){
    Write-Host " [ReportOnly] - wuerde klonen..." -ForegroundColor DarkGray
    return $null
  }

  git clone $url $dest
  if ($LASTEXITCODE -ne 0){
    Write-Host "Clone fehlgeschlagen fuer $url" -ForegroundColor Red
    return $null
  }
  return $dest
}

function ChooseUrl($repo, [switch]$UseHttps){
  if ($UseHttps) {
    if ($repo.cloneUrl) { return $repo.cloneUrl }
  } else {
    if ($repo.sshUrl)   { return $repo.sshUrl }
  }
  if ($repo.cloneUrl) { return $repo.cloneUrl }
  return $repo.sshUrl
}

function Get-FirstTopic($repo){
  # GH CLI liefert i.d.R. .topics als Array von Strings (falls angefordert).
  # REST API liefert .topics ebenfalls (Token kann noetig sein).
  $topic = $null
  if ($repo.PSObject.Properties.Match('topics').Count -gt 0) {
    $t = $repo.topics
    if ($t -and $t.Count -gt 0) { $topic = [string]$t[0] }
  } elseif ($repo.PSObject.Properties.Match('repositoryTopics').Count -gt 0) {
    # Fallback-Schema mancher gh-Versionen
    $rt = $repo.repositoryTopics
    if ($rt -and $rt.nodes -and $rt.nodes.Count -gt 0) {
      $topic = [string]$rt.nodes[0].topic.name
    }
  }
  if ([string]::IsNullOrWhiteSpace($topic)) { $topic = 'misc' }
  return $topic
}

function CategoryFor($repo){
  if ($CategorizeByTopic) {
    return (Get-FirstTopic $repo)
  }
  if ($CategorizeByLanguage) {
    $lang = $repo.primaryLanguage
    if ([string]::IsNullOrWhiteSpace($lang)) { $lang = "misc" }
    return $lang
  }
  return $repo.owner.login
}

function Get-RemoteReposGh($owner){
  # Versuche, topics gleich mit zu holen; falls nicht verfuegbar, bleibt .topics leer -> Get-FirstTopic faellt auf 'misc'
  $json = gh repo list $owner --limit 1000 --json name,sshUrl,cloneUrl,isArchived,isFork,owner,primaryLanguage,visibility,topics 2>$null
  if (-not $json) { return @() }
  return $json | ConvertFrom-Json
}

function Get-RemoteReposApi($owner){
  $repos = @()
  $page = 1
  $token = $Env:GITHUB_TOKEN
  $headers = @{ "Accept"="application/vnd.github+json" }
  if ($token) { $headers["Authorization"] = "Bearer $token" }

  while ($true) {
    $uri = "https://api.github.com/users/$owner/repos?per_page=100&page=$page&type=owner&sort=full_name&direction=asc"
    try {
      $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
    } catch {
      throw "GitHub API Fehler: $($_.Exception.Message) (Tipp: gh auth login oder GITHUB_TOKEN setzen)"
    }
    if (-not $resp -or $resp.Count -eq 0) { break }

    foreach($r in $resp){
      $visibility = "public"
      if ($r.private) { $visibility = "private" }
      # topics wird i.d.R. mitgeliefert; sonst null -> CategoryFor faellt auf misc
      $obj = [pscustomobject]@{
        name            = $r.name
        sshUrl          = $r.ssh_url
        cloneUrl        = $r.clone_url
        isArchived      = [bool]$r.archived
        isFork          = [bool]$r.fork
        owner           = @{ login = $r.owner.login }
        primaryLanguage = $r.language
        visibility      = $visibility
        topics          = $r.topics
      }
      $repos += $obj
    }
    $page++
  }
  return $repos
}

# ================== Start ==================
try {
  if ($ShowHelp) { Show-Usage; return }

  Require-Git
  if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }

  if ($ReportOnly -and $PullOnlyChanged) {
    Show-Usage "Optionen inkompatibel: -ReportOnly kann nicht mit -PullOnlyChanged kombiniert werden."
    return
  }

  if ($ShowSyntax) { Show-SyntaxInfo }

  # Owner automatisch bestimmen, wenn fuer Clone benoetigt
  $needOwner = ($Mode -eq 'Clone' -or $Mode -eq 'Both')
  if ($needOwner -and (-not $Owner)) {
    $auto = Get-DefaultOwner
    if ($auto) {
      Write-Host "Kein -Owner angegeben - nutze angemeldeten Account: $auto" -ForegroundColor DarkGray
      $Owner = $auto
    } else {
      Show-Usage "Owner wird fuer -Mode $Mode benoetigt und konnte nicht automatisch ermittelt werden."
      return
    }
  }

  # --- CLONE-PHASE ---
  if ($Mode -eq 'Clone' -or $Mode -eq 'Both') {
    $remoteRepos = @()
    if ($UseGh -or (HasGh)) {
      try { $remoteRepos = Get-RemoteReposGh $Owner } catch { Write-Host "gh-Abfrage fehlgeschlagen, versuche API ..." -ForegroundColor Yellow }
    }
    if (-not $remoteRepos -or $remoteRepos.Count -eq 0) {
      $remoteRepos = Get-RemoteReposApi $Owner
    }
    if (-not $remoteRepos -or $remoteRepos.Count -eq 0) {
      throw "Keine Remote-Repos fuer '$Owner' gefunden (Rechte/Sichtbarkeit pruefen)."
    }

    $filtered = $remoteRepos | Where-Object {
      ($IncludeForks -or (-not $_.isFork)) -and
      ($IncludeArchived -or (-not $_.isArchived))
    }
    if (-not $filtered -or $filtered.Count -eq 0) {
      Write-Host "Nach Filter keine Repos uebrig (Forks/Archived?)." -ForegroundColor Yellow
    } else {
      foreach($r in $filtered){
        $cat  = CategoryFor $r
        $url  = ChooseUrl $r -UseHttps:$UseHttps
        $name = $r.name
        $dest = Ensure-Cloned -root $Root -category $cat -name $name -url $url
        if ($Mode -eq 'Both' -and $dest) {
          Pull-ExistingRepo -repoPath $dest
        }
      }
    }
  }

  # --- PULL-PHASE (alle lokalen unter Root) ---
  if ($Mode -eq 'Pull') {
    $gitDirs = Get-ChildItem -Path $Root -Recurse -Directory -Filter .git -ErrorAction SilentlyContinue
    if (-not $gitDirs) { Show-Usage "Keine Repos unter $Root gefunden."; return }
    foreach($g in $gitDirs) {
      Pull-ExistingRepo -repoPath $g.Parent.FullName
    }
  }

  Write-Host "`nFertig." -ForegroundColor Cyan
}
catch {
  Show-Usage $_.Exception.Message
}
