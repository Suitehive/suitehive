<#
.SYNOPSIS
  Suitehive installer for Windows: try Suitehive locally with Docker Desktop.

.DESCRIPTION
  The Windows equivalent of `suitehive install --local`. It sets up a local trial
  of Suitehive (Mail, Calendar, sign-in/SSO and Admin) at http://localhost:8080
  with demo data. Production servers run Linux: use install.sh there.

  What it does:
    1. checks Docker Desktop (with compose v2), memory and that port 8080 is free
    2. writes .env (generated secrets; readable only by you), docker-compose.yml,
       Caddyfile and initdb\ into the install directory
    3. runs `docker compose pull` and `docker compose up -d`
    4. waits for the stack and prints the URLs and demo sign-ins

  Usage (from a clone):
    powershell -ExecutionPolicy Bypass -File install.ps1 [-Dir <path>] [-DryRun] [-Yes]

  Usage (one line, no clone):
    irm https://raw.githubusercontent.com/Suitehive/suitehive/main/install.ps1 | iex

  Piping into iex cannot pass parameters. Either set environment variables first
  ($env:SH_DIR, $env:SH_VERSION, $env:SH_DRY_RUN = "1", $env:SH_YES = "1",
  $env:SH_FORCE = "1"), or run it as a script block:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Suitehive/suitehive/main/install.ps1))) -DryRun

.PARAMETER Dir
  Install directory. Default: $env:SH_DIR, else $HOME\suitehive.
.PARAMETER Version
  Image tag of ghcr.io/suitehive/*. Default: $env:SH_VERSION, else "edge".
.PARAMETER DryRun
  Write all files and show the docker commands without running them.
.PARAMETER Yes
  Do not ask for confirmation.
.PARAMETER Force
  Replace an existing .env with new secrets (fresh start only).
.PARAMETER Build
  Building from source is not supported on Windows; use WSL and install.sh --build.
.PARAMETER Help
  Show this help.
#>
param(
  [string]$Dir = "",
  [string]$Version = "",
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$Force,
  [switch]$Build,
  [switch]$Help
)

# This file must stay ASCII-only and compatible with Windows PowerShell 5.1.
# It never calls `exit` when piped into iex (that would close your console).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliVersion = '0.1.0-dev'
$script:Ref = if ($env:SH_REF) { $env:SH_REF } else { 'main' }
$script:RepoRaw = if ($env:SH_REPO_RAW) { $env:SH_REPO_RAW } else { "https://raw.githubusercontent.com/Suitehive/suitehive/$($script:Ref)" }
$script:RunAsFile = [bool]$PSCommandPath
$script:ScriptRoot = $PSScriptRoot
$script:UseColor = -not $env:NO_COLOR
$script:HealthTimeout = 180
$script:DemoPassword = 'suitehive-dev'
$script:DemoUsers = @('admin', 'priya', 'alex')

# ------------------------------------------------------------------ output --

function Write-Step([string]$Text) {
  if ($script:UseColor) { Write-Host '==> ' -ForegroundColor Blue -NoNewline } else { Write-Host '==> ' -NoNewline }
  Write-Host $Text
}
function Write-Ok([string]$Text) {
  if ($script:UseColor) { Write-Host '    + ' -ForegroundColor Green -NoNewline } else { Write-Host '    + ' -NoNewline }
  Write-Host $Text
}
function Write-Note([string]$Text) {
  if ($script:UseColor) { Write-Host "    $Text" -ForegroundColor DarkGray } else { Write-Host "    $Text" }
}
function Write-Warn([string]$Text) {
  if ($script:UseColor) { Write-Host "warning: $Text" -ForegroundColor Yellow } else { Write-Host "warning: $Text" }
}
function Write-Dry([string]$Text) { Write-Note "[dry-run] $Text" }
function Write-Kv([string]$Key, [string]$Value) { Write-Host ('  {0,-13} {1}' -f $Key, $Value) }

# Fail stops the installer: it throws, and the caller at the bottom prints it.
function Fail([string]$Text) { throw "SUITEHIVE: $Text" }

# ----------------------------------------------------------------- helpers --

# Invoke-Native runs an external program and returns its exit code and stdout.
# (In PowerShell 5.1 redirecting a native program's stderr while
# ErrorActionPreference is Stop turns stderr lines into terminating errors.)
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @ArgList 2>$null
    return @{ Code = $LASTEXITCODE; Out = (($out | Out-String).Trim()) }
  } catch {
    return @{ Code = 1; Out = '' }
  } finally {
    $ErrorActionPreference = $old
  }
}

# Invoke-Visible runs an external program with its output on the console.
function Invoke-Visible([string]$Exe, [string[]]$ArgList) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Exe @ArgList
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $old
  }
}

function Test-Interactive {
  if ($Yes -or $env:SH_YES -eq '1') { return $false }
  try {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
  } catch {
    return $false
  }
}

function Confirm-Continue([string]$Question) {
  if (-not (Test-Interactive)) { return $true }
  $answer = Read-Host "? $Question [Y/n]"
  return ($answer -eq '' -or $answer -match '^(y|yes)$')
}

# Random secrets from the OS CSPRNG.
function New-RandomBytes([int]$Count) {
  $bytes = New-Object byte[] $Count
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return , $bytes
}

function New-Base64Secret([int]$Count) {
  return [Convert]::ToBase64String((New-RandomBytes $Count))
}

# Letters and digits only (safe inside database URLs). Rejection sampling keeps
# the distribution uniform.
function New-AlnumSecret([int]$Length) {
  $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $sb = New-Object System.Text.StringBuilder
  while ($sb.Length -lt $Length) {
    foreach ($b in (New-RandomBytes 64)) {
      if ($b -lt 248 -and $sb.Length -lt $Length) { [void]$sb.Append($alphabet[$b % 62]) }
    }
  }
  return $sb.ToString()
}

# Read-DotEnv returns a hashtable of KEY -> value (surrounding quotes removed).
function Read-DotEnv([string]$Path) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $value = $Matches[2].TrimEnd("`r")
      if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      $map[$Matches[1]] = $value
    }
  }
  return $map
}

# Write-TextFile writes UTF-8 without BOM and with LF line endings, which is
# what docker compose expects for .env.
function Write-TextFile([string]$Path, [string]$Content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), $utf8NoBom)
}

# Get-Template copies a template from the local clone, or downloads it.
function Get-Template([string]$RelPath, [string]$Dest) {
  $parent = Split-Path -Parent $Dest
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  $local = $null
  if ($script:ScriptRoot) { $local = Join-Path (Join-Path $script:ScriptRoot 'templates') $RelPath }
  $tmp = "$Dest.new"
  if ($local -and (Test-Path -LiteralPath $local)) {
    Copy-Item -LiteralPath $local -Destination $tmp -Force
  } else {
    $url = "$($script:RepoRaw)/templates/$($RelPath -replace '\\', '/')"
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
    } catch {
      Fail "could not download $url ($($_.Exception.Message))"
    }
  }
  if ((Get-Item -LiteralPath $tmp).Length -eq 0) { Fail "template $RelPath is empty" }
  if (Test-Path -LiteralPath $Dest) {
    $old = [System.IO.File]::ReadAllText($Dest)
    $new = [System.IO.File]::ReadAllText($tmp)
    if ($old -ne $new) {
      Copy-Item -LiteralPath $Dest -Destination "$Dest.bak" -Force
      Write-Note "updated $(Split-Path -Leaf $Dest) (previous version kept as .bak)"
    }
  }
  Move-Item -LiteralPath $tmp -Destination $Dest -Force
}

function Get-TemplatesSource {
  if ($script:ScriptRoot -and (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\docker-compose.yml'))) {
    return (Join-Path $script:ScriptRoot 'templates')
  }
  return "$($script:RepoRaw)/templates"
}

# ------------------------------------------------------------------ checks --

function Test-Docker([bool]$Soft) {
  $problem = $null
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $problem = "Docker is not installed. Install Docker Desktop (https://www.docker.com/products/docker-desktop/), start it, and run this again."
  } else {
    $server = Invoke-Native 'docker' @('version', '--format', '{{.Server.Version}}')
    if ($server.Code -ne 0 -or -not $server.Out) {
      $problem = "Docker Desktop is not running (the Docker daemon is not reachable). Start Docker Desktop and try again."
    } else {
      $compose = Invoke-Native 'docker' @('compose', 'version', '--short')
      if ($compose.Code -ne 0) {
        $problem = "docker compose v2 is missing. Update Docker Desktop."
      } else {
        Write-Ok "docker $($server.Out), compose $($compose.Out)"
      }
    }
  }
  if ($problem) {
    if ($Soft) { Write-Warn "$problem (ignored for -DryRun)" } else { Fail $problem }
  }
}

function Test-Memory {
  $bytes = $null
  try {
    $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
  } catch {
    try { $bytes = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory } catch { $bytes = $null }
  }
  if (-not $bytes) {
    Write-Warn "could not determine the amount of memory; Suitehive needs about 4 GB for Docker"
    return
  }
  $gib = [math]::Round($bytes / 1GB, 1)
  if ($bytes -ge 3.5GB) {
    Write-Ok "memory: $gib GiB (give Docker Desktop at least 4 GB in Settings > Resources)"
  } else {
    Write-Warn "only $gib GiB of memory; Suitehive needs about 4 GB (continuing anyway)"
  }
}

function Test-PortInUse([int]$Port) {
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$c
  }
  $netstat = Invoke-Native 'netstat' @('-an')
  return [bool]($netstat.Out -split "`n" | Where-Object { $_ -match "[.:]$Port\s" -and $_ -match 'LISTEN' })
}

function Test-Ports([int[]]$Ports) {
  $taken = @()
  foreach ($p in $Ports) { if (Test-PortInUse $p) { $taken += $p } }
  if ($taken.Count -gt 0) {
    Write-Warn "ports already in use: $($taken -join ', '). If this is an earlier Suitehive install that is fine; otherwise stop whatever listens there."
  } else {
    Write-Ok "ports free: $($Ports -join ', ')"
  }
}

# Restrict .env to the current user (best effort; it holds the secrets).
function Protect-File([string]$Path) {
  try {
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $r = Invoke-Native 'icacls' @($Path, '/inheritance:r', '/grant:r', "${who}:(R,W)")
    if ($r.Code -ne 0) { Write-Warn "could not restrict access to $Path (icacls failed)" }
  } catch {
    Write-Warn "could not restrict access to $Path"
  }
}

function Wait-Healthy([string]$Url) {
  $deadline = (Get-Date).AddSeconds($script:HealthTimeout)
  Write-Host "    waiting for auth (up to $($script:HealthTimeout)s) " -NoNewline
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
      if ($r.StatusCode -eq 200) {
        Write-Host ' ready' -ForegroundColor Green
        return $true
      }
    } catch {
      # not up yet
    }
    Write-Host '.' -NoNewline
    Start-Sleep -Seconds 3
  }
  Write-Host ' timed out' -ForegroundColor Red
  return $false
}

# -------------------------------------------------------------------- main --

function Install-Suitehive {
  if ($Help) {
    Get-Help -Detailed $PSCommandPath -ErrorAction SilentlyContinue
    if (-not $PSCommandPath) {
      Write-Host 'Suitehive installer for Windows (local trial). Parameters: -Dir <path> -Version <tag> -DryRun -Yes -Force'
      Write-Host 'See https://github.com/Suitehive/suitehive for documentation.'
    }
    return
  }
  if ($Build) {
    Fail "-Build is not supported on Windows. Use WSL (Ubuntu) and run: curl -fsSL $($script:RepoRaw)/install.sh | sh -s -- --local --build"
  }

  # TLS 1.2 for downloads on older Windows PowerShell defaults.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch { }

  $isDry = $DryRun -or ($env:SH_DRY_RUN -eq '1')
  $isForce = $Force -or ($env:SH_FORCE -eq '1')
  $installDir = $Dir
  if (-not $installDir) { $installDir = $env:SH_DIR }
  if (-not $installDir) { $installDir = Join-Path $HOME 'suitehive' }
  $installDir = [System.IO.Path]::GetFullPath($installDir)
  $envPath = Join-Path $installDir '.env'
  $prev = Read-DotEnv $envPath

  $tag = $Version
  if (-not $tag) { $tag = $env:SH_VERSION }
  if (-not $tag -and $prev.ContainsKey('SH_VERSION')) { $tag = $prev['SH_VERSION'] }
  if (-not $tag) { $tag = 'edge' }
  $authPort = 8081
  $httpPort = 8080
  $publicUrl = "http://localhost:$httpPort"

  Write-Host 'Suitehive installer' -ForegroundColor White
  if ($isDry) { Write-Note 'dry run: files are written, nothing is started' }
  Write-Host ''
  Write-Kv 'Directory' $installDir
  Write-Kv 'Mode' 'local trial (demo data, plain HTTP)'
  Write-Kv 'URL' $publicUrl
  Write-Kv 'Images' "ghcr.io/suitehive/*:$tag"
  Write-Host ''
  if (-not (Confirm-Continue 'Continue?')) { Fail 'cancelled; nothing was changed' }

  # 1. checks
  Write-Step 'Checking prerequisites'
  Test-Docker $isDry
  Test-Memory
  Test-Ports @($httpPort, 8443, $authPort)

  # 2. secrets: keep the existing ones unless -Force
  Write-Step 'Generating secrets'
  $keep = ($prev.Count -gt 0) -and -not $isForce
  $secretNames = @('SH_MASTER_KEY', 'SH_POSTGRES_PASSWORD', 'SH_MAIL_CLIENT_SECRET', 'SH_CALENDAR_CLIENT_SECRET')
  $secrets = @{}
  foreach ($name in $secretNames) {
    if ($keep -and $prev.ContainsKey($name) -and $prev[$name]) { $secrets[$name] = $prev[$name] }
  }
  if ($prev.Count -gt 0 -and $isForce) {
    Write-Warn '-Force: replacing .env with NEW secrets (existing data volumes will no longer open).'
    Copy-Item -LiteralPath $envPath -Destination "$envPath.before-force" -Force
  }
  if (-not $secrets.ContainsKey('SH_MASTER_KEY')) { $secrets['SH_MASTER_KEY'] = New-Base64Secret 32 }
  if (-not $secrets.ContainsKey('SH_POSTGRES_PASSWORD')) { $secrets['SH_POSTGRES_PASSWORD'] = New-AlnumSecret 32 }
  if (-not $secrets.ContainsKey('SH_MAIL_CLIENT_SECRET')) { $secrets['SH_MAIL_CLIENT_SECRET'] = New-AlnumSecret 40 }
  if (-not $secrets.ContainsKey('SH_CALENDAR_CLIENT_SECRET')) { $secrets['SH_CALENDAR_CLIENT_SECRET'] = New-AlnumSecret 40 }
  if ($keep) { Write-Ok 'kept the existing secrets from .env' } else { Write-Ok 'master key, database password and service credentials generated' }

  # 3. files
  Write-Step "Writing configuration to $installDir"
  foreach ($d in @($installDir, (Join-Path $installDir 'initdb'), (Join-Path $installDir 'backups'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
  }
  Write-Note "templates: $(Get-TemplatesSource)"
  Get-Template 'docker-compose.yml' (Join-Path $installDir 'docker-compose.yml')
  Get-Template 'Caddyfile' (Join-Path $installDir 'Caddyfile')
  Get-Template 'initdb/01-databases.sql' (Join-Path $installDir 'initdb\01-databases.sql')

  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
  $lines = @(
    "# Suitehive settings, written by install.ps1 ($($script:CliVersion)) on $stamp.",
    '# Every key is documented in templates/env.example in the suitehive repo.',
    '# Keep this file private: it contains your secrets.',
    '',
    '# Release (image tag of ghcr.io/suitehive/*)',
    "SH_VERSION=$tag",
    '',
    '# Identity',
    'SH_DOMAIN=suitehive.local',
    'SH_HOSTNAME=localhost',
    "SH_PUBLIC_URL=$publicUrl",
    'SH_SITE_ADDRESS=:80',
    'SH_TLS_EMAIL=admin@suitehive.local',
    'SH_ORG_NAME=Demo',
    'SH_ORG_SLUG=demo',
    'SH_ADMIN_EMAIL=admin@suitehive.local',
    'SH_ADMIN_NAME=Admin',
    '',
    '# Mode',
    'SH_LOCAL=true',
    'SH_BUILD=false',
    '',
    '# Host ports (SH_AUTH_LOCAL_PORT is bound to 127.0.0.1 only)',
    "SH_HTTP_PORT=$httpPort",
    'SH_HTTPS_PORT=8443',
    'SH_SMTP_PORT=2525',
    'SH_SMTPS_PORT=2465',
    'SH_SUBMISSION_PORT=2587',
    'SH_IMAPS_PORT=1993',
    "SH_AUTH_LOCAL_PORT=$authPort",
    '',
    '# Development flags (local trial only)',
    'SH_DEV_SEED=true',
    'SH_DEV_INSECURE_COOKIES=true',
    'SH_LOG_LEVEL=info',
    '',
    '# Secrets: generated once. Do not change them on a running install.',
    "SH_MASTER_KEY=$($secrets['SH_MASTER_KEY'])",
    "SH_POSTGRES_PASSWORD=$($secrets['SH_POSTGRES_PASSWORD'])",
    "SH_MAIL_CLIENT_SECRET=$($secrets['SH_MAIL_CLIENT_SECRET'])",
    "SH_CALENDAR_CLIENT_SECRET=$($secrets['SH_CALENDAR_CLIENT_SECRET'])"
  )
  # Carry over settings this installer does not manage (e.g. SH_EMAIL_SMTP_URL).
  $managed = @{}
  foreach ($l in $lines) { if ($l -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $managed[$Matches[1]] = $true } }
  $extra = @()
  if (Test-Path -LiteralPath $envPath) {
    foreach ($l in [System.IO.File]::ReadAllLines($envPath)) {
      if ($l -match '^([A-Za-z_][A-Za-z0-9_]*)=' -and -not $managed.ContainsKey($Matches[1])) { $extra += $l.TrimEnd("`r") }
    }
  }
  if ($extra.Count -gt 0) { $lines += @('', '# Your own settings (kept from the previous .env)') + $extra }
  Write-TextFile $envPath (($lines -join "`n") + "`n")
  Protect-File $envPath
  Write-Ok '.env (your user only), docker-compose.yml, Caddyfile, initdb\'

  # docker compose lets SH_* variables of this shell override .env; .env must win.
  Get-ChildItem env: | Where-Object { $_.Name -like 'SH_*' } | ForEach-Object { Remove-Item -LiteralPath "env:$($_.Name)" }

  # 4. start
  $composeArgs = @('compose', '--project-directory', $installDir, '-f', (Join-Path $installDir 'docker-compose.yml'))
  $healthy = $true
  if ($isDry) {
    Write-Step 'Pulling images'
    Write-Dry ("docker " + (($composeArgs + 'pull') -join ' '))
    Write-Step 'Starting Suitehive'
    Write-Dry ("docker " + (($composeArgs + @('up', '-d', '--remove-orphans')) -join ' '))
    Write-Step 'Waiting for Suitehive to start'
    Write-Dry "wait up to $($script:HealthTimeout)s for http://127.0.0.1:$authPort/healthz"
  } else {
    Write-Step 'Pulling images'
    if ((Invoke-Visible 'docker' ($composeArgs + 'pull')) -ne 0) { Fail 'docker compose pull failed (see above)' }
    Write-Step 'Starting Suitehive'
    if ((Invoke-Visible 'docker' ($composeArgs + @('up', '-d', '--remove-orphans'))) -ne 0) { Fail 'docker compose up failed (see above)' }
    Write-Step 'Waiting for Suitehive to start'
    $healthy = Wait-Healthy "http://127.0.0.1:$authPort/healthz"
    if (-not $healthy) {
      Write-Warn "auth did not become healthy in time. Check: docker compose --project-directory `"$installDir`" logs auth"
    }
  }

  # 5. summary
  Write-Host ''
  if ($isDry) {
    Write-Host "Dry run complete: configuration written to $installDir, nothing started." -ForegroundColor White
  } elseif ($healthy) {
    Write-Host 'Suitehive is running.' -ForegroundColor Green
  } else {
    Write-Host 'Suitehive was started but is not healthy yet.' -ForegroundColor Yellow
  }
  Write-Host ''
  Write-Kv 'Mail' "$publicUrl/mail"
  Write-Kv 'Calendar' "$publicUrl/calendar"
  Write-Kv 'Admin' "$publicUrl/admin"
  Write-Kv 'Install dir' $installDir
  Write-Kv 'Version' $tag
  Write-Host ''
  Write-Host "Demo sign-in (password: $($script:DemoPassword))" -ForegroundColor White
  foreach ($u in $script:DemoUsers) { Write-Kv '' "$u@suitehive.local" }
  Write-Host ''
  Write-Note 'Mail clients: IMAP localhost:1993 (TLS, self-signed), SMTP localhost:2587'
  Write-Note 'This trial uses plain HTTP and demo data: do not expose it to the internet.'
  Write-Note "Stop it:  docker compose --project-directory `"$installDir`" down"
  Write-Note "Logs:     docker compose --project-directory `"$installDir`" logs -f auth"
}

try {
  Install-Suitehive
} catch {
  $msg = $_.Exception.Message
  if ($msg.StartsWith('SUITEHIVE: ')) { $msg = $msg.Substring(11) }
  if ($script:UseColor) { Write-Host "error: $msg" -ForegroundColor Red } else { Write-Host "error: $msg" }
  if ($script:RunAsFile) { exit 1 }
}
