# Tether plugin SessionStart hook: ensure tether-mcp.exe is present
# at ${CLAUDE_PLUGIN_DATA}/tether-mcp.exe and matches the version
# pinned in ${CLAUDE_PLUGIN_ROOT}/version.txt.
#
# Resolution order:
#   1. Dev override - if ${CLAUDE_PLUGIN_ROOT}/bin/tether-mcp.exe exists
#      (a maintainer's locally-built binary), copy it verbatim.
#   2. Cached - if ${CLAUDE_PLUGIN_DATA}/tether-mcp.version matches
#      version.txt and the .exe exists, no-op.
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
    Write-Host "[tether/ensure-binary] $msg"
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

New-Item -ItemType Directory -Force -Path $data | Out-Null

$target = Join-Path $data 'tether-mcp.exe'
$marker = Join-Path $data 'tether-mcp.version'

# --- 1) Dev override ---
$devOverride = Join-Path $root 'bin\tether-mcp.exe'
if (Test-Path -LiteralPath $devOverride) {
    try {
        Copy-Item -LiteralPath $devOverride -Destination $target -Force
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
    Log "downloading tether-mcp.exe@$tag from EntityReborn/tether-plugin"
    # gh release download exits non-zero on failure (auth, not found,
    # network). Capture exit code without throwing so we can give a
    # cleaner error message than PowerShell's default.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & gh release download $tag `
            --repo EntityReborn/tether-plugin `
            --pattern 'tether-mcp.exe' `
            --pattern 'tether-mcp.exe.sha256' `
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

    $dlExe = Join-Path $tmpDir 'tether-mcp.exe'
    $dlSha = Join-Path $tmpDir 'tether-mcp.exe.sha256'

    if (-not (Test-Path -LiteralPath $dlExe)) {
        Log "ERROR: tether-mcp.exe missing from release $tag"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $dlSha)) {
        Log "ERROR: tether-mcp.exe.sha256 missing from release $tag"
        exit 1
    }

    # --- 5) Verify SHA-256 ---
    # The sidecar file is `<hex>  tether-mcp.exe` (sha256sum format)
    # or just `<hex>` (Get-FileHash style). Take the first whitespace-
    # separated token to handle both.
    $expected = (Get-Content -LiteralPath $dlSha -Raw).Trim() -split '\s+' | Select-Object -First 1
    $expected = $expected.ToLower()
    $actual = (Get-FileHash -LiteralPath $dlExe -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) {
        Log "ERROR: SHA-256 mismatch for tether-mcp.exe at $tag"
        Log "  expected (from $tag/tether-mcp.exe.sha256): $expected"
        Log "  actual:                                     $actual"
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
        $wanted | Set-Content -LiteralPath $marker -NoNewline
        Log "installed tether-mcp.exe v$wanted (sha256 $($actual.Substring(0,16))...)"
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
