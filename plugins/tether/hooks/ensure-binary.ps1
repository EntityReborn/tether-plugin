# Tether plugin SessionStart hook: ensure the tether-mcp binary is
# present at ${CLAUDE_PLUGIN_DATA}/<binary> and matches the version
# pinned in ${CLAUDE_PLUGIN_ROOT}/version.txt.
#
# Cross-platform: this script runs under PowerShell 7 (pwsh) on
# Windows, Linux, and macOS (see plugin.json / hooks.json - both
# invoke `pwsh`, not Windows PowerShell). The platform decides:
#   - the binary name: tether-mcp.exe (Windows) vs tether-mcp (POSIX)
#   - the published release asset to download (per OS/arch)
#   - whether the installed binary needs an exec bit (POSIX: chmod +x)
# Windows + Linux ship today; macOS is not yet published and exits
# with a clear error rather than downloading an unusable asset.
#
# Resolution order:
#   1. Dev override - if ${CLAUDE_PLUGIN_ROOT}/bin/<binary> exists
#      (a maintainer's locally-built binary), copy it verbatim.
#   2. Cached - if ${CLAUDE_PLUGIN_DATA}/tether-mcp.version matches
#      version.txt and the binary exists, no-op.
#   3. Download - use `gh release download v<version>` against
#      EntityReborn/tether-plugin, verify SHA-256 against the published
#      sidecar, atomically replace the cached binary.
#
# Requires the GitHub CLI (`gh`) to be installed and authenticated by
# the tech (`gh auth login`) with read access to the plugin repo.
#
# Exits 0 on success or recoverable conditions (cached, dev override,
# binary in use). Exits 1 only on integrity-check failures (SHA
# mismatch) or unrecoverable misconfiguration (no version.txt). The
# MCP server will surface a clearer error later if the binary is
# missing.

$ErrorActionPreference = 'Stop'

function Log {
    param([string]$msg)
    # Stderr only - this script is reused by launch-tether-mcp.ps1 as part of
    # the MCP server spawn, where the script's stdout is the MCP JSON-RPC
    # channel and must stay byte-clean. Hooks (SessionStart) also work fine
    # with stderr.
    [Console]::Error.WriteLine("[tether/ensure-binary] $msg")
}

# Resolve required env vars. Claude Code substitutes ${CLAUDE_PLUGIN_*}
# into the hook command line BEFORE invoking PowerShell, so by the time
# this script runs they are normal $env: values - the substitution at
# hook-command-parse time and the env-var resolution here are two
# separate steps and both must succeed.
$root = $env:CLAUDE_PLUGIN_ROOT
$data = $env:CLAUDE_PLUGIN_DATA
if (-not $root -or -not $data) {
    Log "CLAUDE_PLUGIN_ROOT or CLAUDE_PLUGIN_DATA not set; skipping (was the hook invoked outside Claude Code?)"
    exit 0
}

# --- 0) Resolve platform: binary name + release asset ---
# $IsWindows / $IsLinux / $IsMacOS are PowerShell Core (pwsh)
# automatic variables; they are always defined here because the
# plugin invokes `pwsh`. The release asset names are produced by
# RemoteClaude's release.yml: tether-mcp.exe (windows/amd64) and
# tether-mcp-linux-amd64 (linux/amd64), each with a .sha256 sidecar.
if ($IsMacOS) {
    Log "ERROR: tether-mcp is not yet published for macOS (Windows + Linux only)."
    Log "  macOS support is planned; see https://github.com/EntityReborn/tether-plugin for updates."
    exit 1
}
if ($IsWindows) {
    $exeName   = 'tether-mcp.exe'
    $assetExe  = 'tether-mcp.exe'
} else {
    # Linux (the macOS branch already exited above).
    $exeName   = 'tether-mcp'
    $assetExe  = 'tether-mcp-linux-amd64'
}
$assetSha = "$assetExe.sha256"

# chmod +x on POSIX; no-op on Windows. PowerShell's file cmdlets
# (Copy-Item / Move-Item) do not set the executable bit, so the
# freshly-installed native binary would be non-executable without this.
function Set-ExecBit {
    param([string]$path)
    if (-not $IsWindows) {
        & chmod '+x' $path
    }
}

New-Item -ItemType Directory -Force -Path $data | Out-Null

$target = Join-Path $data $exeName
$marker = Join-Path $data 'tether-mcp.version'

# --- 1) Dev override ---
$devOverride = Join-Path $root 'bin' $exeName
if (Test-Path -LiteralPath $devOverride) {
    try {
        Copy-Item -LiteralPath $devOverride -Destination $target -Force
        Set-ExecBit $target
        "dev-$(Get-Date -Format yyyyMMddHHmmss)" | Set-Content -LiteralPath $marker -NoNewline
        Log "using dev-override binary from $devOverride"
    } catch {
        Log "WARN: could not install dev-override binary: $_"
    }
    exit 0
}

# --- 2) Read pinned version ---
$versionFile = Join-Path $root 'version.txt'
if (-not (Test-Path -LiteralPath $versionFile)) {
    Log "ERROR: $versionFile missing; cannot determine which binary to fetch"
    exit 1
}
$wanted = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if (-not $wanted) {
    Log "ERROR: $versionFile is empty"
    exit 1
}

# --- 3) Cached? ---
$current = ''
if (Test-Path -LiteralPath $marker) {
    $current = (Get-Content -LiteralPath $marker -Raw).Trim()
}
if ($current -eq $wanted -and (Test-Path -LiteralPath $target)) {
    Log "cached binary at v$wanted is current"
    exit 0
}

# --- 4) Download via gh ---
# gh handles private-repo auth automatically using the tech's
# `gh auth login` credentials. We deliberately do NOT use
# Invoke-WebRequest with a hard-coded token: every tech authenticates
# with their own identity, so deprovisioning a person is just
# revoking their GitHub access.
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Log "ERROR: 'gh' (GitHub CLI) not found on PATH."
    Log "  Install from https://cli.github.com and run 'gh auth login'."
    exit 1
}

$tag = "v$wanted"
$tmpDir = Join-Path $data ".download-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
    Log "downloading $assetExe@$tag from EntityReborn/tether-plugin"
    # gh release download exits non-zero on failure (auth, not found,
    # network). Capture exit code without throwing so we can give a
    # cleaner error message than PowerShell's default.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & gh release download $tag `
            --repo EntityReborn/tether-plugin `
            --pattern $assetExe `
            --pattern $assetSha `
            --dir $tmpDir 2>&1 | ForEach-Object { Log "  gh: $_" }
        $ghExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($ghExit -ne 0) {
        Log "ERROR: gh release download failed (exit $ghExit)."
        Log "  Hint: run 'gh auth login' and confirm read access to EntityReborn/tether-plugin."
        Log "  Also verify a release tagged '$tag' exists at https://github.com/EntityReborn/tether-plugin/releases"
        exit 1
    }

    $dlExe = Join-Path $tmpDir $assetExe
    $dlSha = Join-Path $tmpDir $assetSha

    if (-not (Test-Path -LiteralPath $dlExe)) {
        Log "ERROR: $assetExe missing from release $tag"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $dlSha)) {
        Log "ERROR: $assetSha missing from release $tag"
        exit 1
    }

    # --- 5) Verify SHA-256 ---
    # The sidecar file is `<hex>  <asset>` (sha256sum format) or just
    # `<hex>` (Get-FileHash style). Take the first whitespace-
    # separated token to handle both.
    $expected = (Get-Content -LiteralPath $dlSha -Raw).Trim() -split '\s+' | Select-Object -First 1
    $expected = $expected.ToLower()
    $actual = (Get-FileHash -LiteralPath $dlExe -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) {
        Log "ERROR: SHA-256 mismatch for $assetExe at $tag"
        Log "  expected (from $tag/$assetSha): $expected"
        Log "  actual:                         $actual"
        Log "  Refusing to install; the binary or sidecar may have been tampered with."
        exit 1
    }

    # --- 6) Atomic install ---
    # Move-Item will fail with IOException if the destination is held
    # open by another Claude Code instance. That's recoverable - the
    # existing (older) binary keeps working; the user just needs to
    # restart Claude Code to pick up the new version. Do NOT promote
    # via a .new sidecar - that was removed as a privilege-escalation
    # vector in the source repo's H2 review.
    try {
        Move-Item -LiteralPath $dlExe -Destination $target -Force -ErrorAction Stop
        Set-ExecBit $target
        $wanted | Set-Content -LiteralPath $marker -NoNewline
        Log "installed $exeName v$wanted (sha256 $($actual.Substring(0,16))...)"
    } catch {
        Log "WARN: could not replace $target (likely in use by another Claude Code window): $_"
        Log "  Close all Claude Code windows and reopen to activate v$wanted."
        Log "  The existing binary continues to work in the meantime."
    }
} finally {
    if (Test-Path -LiteralPath $tmpDir) {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
