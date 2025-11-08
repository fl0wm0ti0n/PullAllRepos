[CmdletBinding()]
param(
  # Target structure: GitRepo\<Category>\<Repo>
  [string]$Root = (Join-Path $HOME 'Documents\GitRepo'),

  # GitHub owner (user or org). If empty and -Mode contains Clone -> determine automatically.
  [string]$Owner,

  # Operation mode: Clone = clone missing repos only, Pull = update local repos only, Both = both
  [ValidateSet('Clone','Pull','Both')][string]$Mode = 'Both',

  # Pull options
  [switch]$ReportOnly,
  [switch]$AutoStash,
  [switch]$NoRebase,
  [switch]$NoFetch,
  [switch]$PullOnlyChanged,

  # Remote sources (only for Clone)
  [switch]$UseGh,                 # Prefer GitHub CLI if available
  [switch]$UseHttps,              # Use HTTPS URL instead of SSH
  [switch]$IncludeForks,          # Do NOT filter out forks
  [switch]$IncludeArchived,       # Do NOT filter out archived
  [switch]$CategorizeByLanguage,  # Category = primaryLanguage
  [switch]$CategorizeByTopic,     # Category = first topic (priority over language)

  # Help/Syntax
  [switch]$ShowSyntax,
  [Alias('Help','?')][switch]$ShowHelp
)

$ErrorActionPreference = 'Stop'

function Show-Usage([string]$Reason = $null) {
  if ($Reason) { Write-Host "`n[Error] $Reason" -ForegroundColor Red }
  $lines = @(
    "================= Help / Syntax =================",
    "Usage:",
    "  .\PullOrCloneAllRepos.ps1 [-Root <path>] [-Owner <user|org>] [-Mode Clone|Pull|Both]",
    "                            [-ReportOnly] [-AutoStash] [-NoRebase] [-NoFetch] [-PullOnlyChanged]",
    "                            [-UseGh] [-UseHttps] [-IncludeForks] [-IncludeArchived]",
    "                            [-CategorizeByTopic] [-CategorizeByLanguage] [-ShowSyntax] [-ShowHelp]",
    "",
    "Examples:",
    "  .\PullOrCloneAllRepos.ps1 -Mode Pull                         # update local repos only",
    "  .\PullOrCloneAllRepos.ps1 -Mode Clone -CategorizeByTopic     # categorize missing repos by topic",
    "  .\PullOrCloneAllRepos.ps1 -Owner myOrg -Mode Both            # clone org + pull all",
    "  .\PullOrCloneAllRepos.ps1 -Mode Pull -PullOnlyChanged        # only when behind > 0",
    "",
    "Legend (git status --porcelain):",
    "  XY before the path: X = index (staged), Y = working tree (unstaged)",
    "  M=Modified, A=Added, D=Deleted, R=Renamed, C=Copied, ??=Untracked, !!=Ignored",
    "  Examples: ' M file' (changed, not staged) | 'M  file' (staged) | '?? file' (untracked)",
    "",
    "Upstream status:",
    "  ahead N  = local branch is N commits ahead (not pushed)",
    "  behind N = remote has N newer commits (local is behind)",
    "  both >0  = diverged",
    "",
    "Useful commands:",
    "  git add <file> | git restore <file> | git restore --staged <file>",
    "  git branch --set-upstream-to origin/<branch>",
    "=================================================="
  )
  Write-Host ($lines -join "`n")
}

function Header($t){ Write-Host "`n======== $t ========" -ForegroundColor Cyan }
function Test-GitAvailable { if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git not found (git.exe not in PATH)." } }
function HasGh { return [bool](Get-Command gh -ErrorAction SilentlyContinue) }
function Show-SyntaxInfo { Header "Syntax info"; Show-Usage }

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

function Update-ExistingRepo($repoPath){
  $name = Split-Path $repoPath -Leaf
  Header "$name (pull)"
  if (-not $NoFetch){ git -C $repoPath fetch --all --prune | Out-Null }
  $info = Get-BranchInfo $repoPath
  $up = $(if ($info.Upstream){ $info.Upstream } else { "(no upstream set)" })
  Write-Host (" Branch:   {0}" -f $info.Branch)
  Write-Host (" Upstream: {0}" -f $up)
  if ($info.Upstream){
    $col = $(if ($info.Behind -gt 0){'Yellow'} elseif($info.Ahead -gt 0){'DarkGray'} else {'Green'})
    Write-Host (" Status:   ahead {0} / behind {1}" -f $info.Ahead, $info.Behind) -ForegroundColor $col
  }
  $dirty = Show-DirtyDetails $repoPath
  if ($ReportOnly){ return }

  if ($PullOnlyChanged -and $info.Upstream -and $info.Behind -le 0){
    Write-Host " Skipped (not behind)." -ForegroundColor DarkGray
    return
  }

  if ($dirty -and -not $AutoStash){
    Write-Host " Skipped (dirty). Use -AutoStash to stash automatically." -ForegroundColor Yellow
    return
  }

  $didStash = $false
  if ($dirty -and $AutoStash){
    $msg = "auto-$(Get-Date -Format 'yyyy-MM-ddTHH-mm-ss')"
    git -C $repoPath stash push -u -m $msg | Out-Null
    $didStash = $true
    Write-Host " Auto-stashed: $msg" -ForegroundColor DarkGray
  }

  $pullArgs = @('--all','--prune')
  if ($NoRebase){ $pullArgs = @('--ff-only') + $pullArgs } else { $pullArgs = @('--rebase','--autostash') + $pullArgs }
  $out = git -C $repoPath pull @pullArgs 2>&1
  Write-Host $out

  if ($didStash){
    $pop = git -C $repoPath stash pop 2>&1
    if ($LASTEXITCODE -ne 0){
      Write-Host " Conflicts during stash pop - please resolve manually." -ForegroundColor Red
      Write-Host $pop
    } else {
      Write-Host " Stash applied." -ForegroundColor DarkGray
    }
  }
}

function Get-OrCloneRepo($root, $category, $name, $url){
  $catDir = Join-Path $root $category
  $dest   = Join-Path $catDir $name
  if (-not (Test-Path -LiteralPath $catDir)) { New-Item -ItemType Directory -Path $catDir | Out-Null }

  if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
    Write-Host "Repo exists: $dest" -ForegroundColor DarkGray
    return $dest
  }
  if (Test-Path -LiteralPath $dest -and -not (Test-Path -LiteralPath (Join-Path $dest '.git'))) {
    Write-Host "WARNING: Target exists but is not a Git repo: $dest" -ForegroundColor Yellow
    return $null
  }

  Header "$name (clone)"
  Write-Host " Ziel: $dest"
  Write-Host " URL:  $url"
  if ($ReportOnly){
    Write-Host " [ReportOnly] - would clone..." -ForegroundColor DarkGray
    return $null
  }

  git clone $url $dest
  if ($LASTEXITCODE -ne 0){
    Write-Host "Clone failed for $url" -ForegroundColor Red
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
  # GH CLI usually provides .topics as an array of strings (if requested).
  # REST API also provides .topics (token may be required).
  $topic = $null
  if ($repo.PSObject.Properties.Match('topics').Count -gt 0) {
    $t = $repo.topics
    if ($t -and $t.Count -gt 0) { $topic = [string]$t[0] }
  } elseif ($repo.PSObject.Properties.Match('repositoryTopics').Count -gt 0) {
    # Fallback schema used by some gh versions
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
  # Try to fetch topics as well; if unavailable, .topics remains empty -> Get-FirstTopic falls back to 'misc'
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
      throw "GitHub API error: $($_.Exception.Message) (Tip: run 'gh auth login' or set GITHUB_TOKEN)"
    }
    if (-not $resp -or $resp.Count -eq 0) { break }

    foreach($r in $resp){
      $visibility = "public"
      if ($r.private) { $visibility = "private" }
      # topics are usually included; else null -> CategoryFor falls back to misc
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

  Test-GitAvailable
  if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }

  if ($ReportOnly -and $PullOnlyChanged) {
    Show-Usage "Incompatible options: -ReportOnly cannot be combined with -PullOnlyChanged."
    return
  }

  if ($ShowSyntax) { Show-SyntaxInfo }

  # Determine owner automatically when needed for Clone
  $needOwner = ($Mode -eq 'Clone' -or $Mode -eq 'Both')
  if ($needOwner -and (-not $Owner)) {
    $auto = Get-DefaultOwner
    if ($auto) {
      Write-Host "No -Owner provided - using authenticated account: $auto" -ForegroundColor DarkGray
      $Owner = $auto
    } else {
      Show-Usage "Owner is required for -Mode $Mode and could not be determined automatically."
      return
    }
  }

  # --- CLONE PHASE ---
  if ($Mode -eq 'Clone' -or $Mode -eq 'Both') {
    $remoteRepos = @()
    if ($UseGh -or (HasGh)) {
      try { $remoteRepos = Get-RemoteReposGh $Owner } catch { Write-Host "gh query failed, trying API ..." -ForegroundColor Yellow }
    }
    if (-not $remoteRepos -or $remoteRepos.Count -eq 0) {
      $remoteRepos = Get-RemoteReposApi $Owner
    }
    if (-not $remoteRepos -or $remoteRepos.Count -eq 0) {
      throw "No remote repos found for '$Owner' (check permissions/visibility)."
    }

    $filtered = $remoteRepos | Where-Object {
      ($IncludeForks -or (-not $_.isFork)) -and
      ($IncludeArchived -or (-not $_.isArchived))
    }
    if (-not $filtered -or $filtered.Count -eq 0) {
      Write-Host "No repos left after filtering (forks/archived?)." -ForegroundColor Yellow
    } else {
      foreach($r in $filtered){
        $cat  = CategoryFor $r
        $url  = ChooseUrl $r -UseHttps:$UseHttps
        $name = $r.name
        $dest = Get-OrCloneRepo -root $Root -category $cat -name $name -url $url
        if ($Mode -eq 'Both' -and $dest) {
          Update-ExistingRepo -repoPath $dest
        }
      }
    }
  }

  # --- PULL PHASE (all local repos under Root) ---
  if ($Mode -eq 'Pull') {
    $gitDirs = Get-ChildItem -Path $Root -Recurse -Directory -Filter .git -ErrorAction SilentlyContinue
    if (-not $gitDirs) { Show-Usage "No repos found under $Root."; return }
    foreach($g in $gitDirs) {
      Update-ExistingRepo -repoPath $g.Parent.FullName
    }
  }

  Write-Host "`nDone." -ForegroundColor Cyan
}
catch {
  Show-Usage $_.Exception.Message
}
