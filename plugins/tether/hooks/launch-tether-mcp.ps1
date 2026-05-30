# Tether MCP server launcher.
#
# Cross-platform: runs under PowerShell 7 (pwsh) on Windows, Linux,
# and macOS (plugin.json invokes `pwsh`). The binary name is
# tether-mcp.exe on Windows and tether-mcp on POSIX; ensure-binary.ps1
# installs the right one (and sets +x on POSIX).
#
# Wrapped around the tether-mcp binary because Claude Code spawns plugin MCP servers
# in parallel with (or before) SessionStart hooks complete. On a fresh install
# the binary doesn't exist at MCP spawn time; the server fails and Claude Code
# does not auto-retry once the SessionStart hook later downloads it. This
# wrapper closes the race by synchronously calling ensure-binary.ps1 before
# spawning the .exe.
#
# Stdio contract: tether-mcp.exe writes MCP JSON-RPC on stdout; we keep that
# stream byte-for-byte clean. Wrapper diagnostics go to stderr only. The .exe
# is spawned via Process.Start with inherited stdio (UseShellExecute=false,
# no Redirect*) so PowerShell's object pipeline does not intermediate or
# buffer the child's stdio, which would break MCP framing.

$ErrorActionPreference = 'Stop'

function WriteErr {
    param([string]$msg)
    [Console]::Error.WriteLine("[launch-tether-mcp] $msg")
}

$root = $env:CLAUDE_PLUGIN_ROOT
$data = $env:CLAUDE_PLUGIN_DATA
if (-not $root -or -not $data) {
    WriteErr "CLAUDE_PLUGIN_ROOT or CLAUDE_PLUGIN_DATA not set; aborting (was the MCP server invoked outside Claude Code?)"
    exit 1
}

$exe = Join-Path $data ($IsWindows ? 'tether-mcp.exe' : 'tether-mcp')

# Ensure the binary exists at the pinned version. ensure-binary.ps1 is
# idempotent: when the cached marker matches version.txt, it is a no-op.
# It writes all diagnostics to stderr (see its Log function), so the MCP
# JSON-RPC channel on our stdout stays byte-clean.
$ensure = Join-Path $root 'hooks' 'ensure-binary.ps1'
if (Test-Path -LiteralPath $ensure) {
    & $ensure
    if ($LASTEXITCODE -ne 0) {
        WriteErr "ensure-binary.ps1 exited $LASTEXITCODE; refusing to start MCP server with no binary"
        exit 1
    }
} else {
    WriteErr "ensure-binary.ps1 missing at $ensure; cannot guarantee binary is present"
}

if (-not (Test-Path -LiteralPath $exe)) {
    WriteErr "tether-mcp binary still missing at $exe after ensure-binary; aborting"
    exit 1
}

# Spawn with direct stdio inheritance. UseShellExecute=false plus no
# Redirect* means the child inherits this script's (and therefore Claude
# Code's) stdin/stdout/stderr handles directly - no PowerShell pipeline
# in the middle.
$psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit()
exit $proc.ExitCode
