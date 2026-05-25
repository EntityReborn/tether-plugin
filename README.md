# Tether plugin marketplace

Private distribution hub for the **Tether** remote-Windows MCP plugin.
This repo hosts:

- The Claude Code marketplace, plugin manifest, slash commands, skill,
  and `SessionStart` hook.
- The GitHub Releases that host `tether-mcp.exe`, `tether-launcher.exe`,
  and the `tether.mcpb` Claude Desktop bundle.

The MCP server source code (Go) lives in a separate repo
(`EntityReborn/RemoteClaude`); a tagged release there builds all the
artifacts and uploads them here.

## Install (per tech, once)

Pick one path based on which Claude client you use. Both end up at
the same `mcp__tether__*` tool surface; updates flow through different
mechanisms.

### Claude Code

Prerequisites:

- Windows 10 or 11 (the MCP binary is Windows-only).
- [GitHub CLI](https://cli.github.com) installed and authenticated:

```powershell
gh auth login
```

The account you authenticate with must have read access to this
repo. The SessionStart hook uses `gh release download` under that
identity.

Then in Claude Code:

```
/plugin marketplace add https://github.com/EntityReborn/tether-plugin
/plugin install tether@wildfrog-internal
```

That's it. On the next session start the plugin downloads the matching
`tether-mcp.exe` from this repo's Releases, verifies its SHA-256, and
caches it under the plugin's per-user data directory. Future sessions
reuse the cached copy until `version.txt` changes here.

### Claude Desktop (Pro / Team / Enterprise)

Prerequisites:

- Windows 10 or 11.
- A **paid Claude Desktop tier** (Pro, Team, or Enterprise). Local
  MCP servers are gated to paid plans; free-tier users won't see the
  Extensions panel and should use Claude Code instead.

Steps:

1. Download `tether.mcpb` from the latest Release:
   [`releases/latest`](https://github.com/EntityReborn/tether-plugin/releases/latest)
   ```powershell
   gh release download --repo EntityReborn/tether-plugin --pattern tether.mcpb
   ```
2. Open Claude Desktop -> **Settings** -> **Extensions**.
3. Drag `tether.mcpb` into the panel (or click "Install Extension"
   and browse to it). Approve the permissions prompt.
4. Restart Claude Desktop if the new server doesn't appear in the
   tool picker immediately.

Verify by asking a new conversation *"start a new remote session"* —
Claude should call `mcp__tether__new_session` and read back a code
like `BLUE-FROG-LAZY-CAT`.

## Update flow

When `EntityReborn/RemoteClaude` publishes a new release:

1. Its release CI builds `tether-mcp.exe`, `tether-launcher.exe`, and
   `tether.mcpb`, plus the SHA-256 sidecar for the MCP binary.
2. It creates a Release on **this** repo tagged `v<X.Y.N>` with all
   four artifacts attached.
3. It pushes a commit to this repo bumping `plugins/tether/version.txt`
   and `plugins/tether/.claude-plugin/plugin.json`.

How techs pick up the change:

**Claude Code techs:** run `/plugin marketplace update` (or let
Claude Code auto-update if configured). Next session start, the
SessionStart hook sees the bumped `version.txt`, notices its cached
binary no longer matches, and re-downloads. No manual file handling.

**Claude Desktop techs:** the launcher bundled inside their existing
`tether.mcpb` install hits this repo's Releases API on every Claude
Desktop spawn (3-second budget, SHA-256 verified) and atomically
swaps the cached `tether-mcp.exe` if a newer version is published.
Transparent — no action required. The only time a Claude Desktop
tech needs to re-download `tether.mcpb` is when the launcher itself
changes, which is rare.

## Layout

```
.claude-plugin/marketplace.json          marketplace manifest (1 plugin)
plugins/tether/
  .claude-plugin/plugin.json             plugin manifest
  version.txt                            pinned binary version (e.g. "0.2.61")
  hooks/
    hooks.json                           SessionStart hook wiring
    ensure-binary.ps1                    downloader + integrity check
  commands/                              /remote-new, /remote-list, /remote-end
  skills/tether/SKILL.md                 operating manual
README.md
```

## Dev override

### Claude Code

Maintainers can test a locally-built binary without cutting a release.
Drop the .exe at:

```
plugins/tether/bin/tether-mcp.exe
```

The hook checks for this path first; if present, it's used verbatim
and no download happens. `plugins/tether/bin/` is gitignored, so end
users never see it.

To produce a usable binary:

```powershell
# In the RemoteClaude (source) repo:
.\build.ps1 -Target mcp

# Then copy to the dev-override path:
Copy-Item mcp\builds\tether-mcp.exe ..\tether-plugin\plugins\tether\bin\tether-mcp.exe
```

### Claude Desktop

There's no separate dev-override hook; just install a freshly-built
`.mcpb` directly:

```powershell
# In the RemoteClaude (source) repo:
.\build.ps1 -Target mcpb

# Result: mcp/builds/tether.mcpb
# Drag that into Claude Desktop -> Settings -> Extensions.
# Uninstall the previous Tether extension first if you have one.
```

The bundled launcher will then exec the just-built `tether-mcp.exe`
from inside the bundle (because the cache is empty on first run)
rather than pulling from GitHub Releases. On subsequent spawns it
checks Releases as usual; to force it to stay on the local build,
either keep your network offline or block `api.github.com`.

## Security posture

- Every published `tether-mcp.exe` is accompanied by a SHA-256
  sidecar in the same Release. The Claude Code `SessionStart` hook
  refuses to install if the hashes diverge.
- The Claude Desktop launcher uses the same trust source: it pulls
  `tether-mcp.exe` from this repo's GitHub Releases over HTTPS and
  SHA-256-verifies the bytes against the matching sidecar before
  swapping the cached binary. Mismatch -> reject the update, keep
  the cached (or bundled fallback) binary. The launcher does NOT
  trust any local sidecar (`.new`, `~`, etc.) — that path was
  identified as a privilege-escalation primitive (H2 in the source
  repo's security review) and removed in v0.2.13. See
  `EntityReborn/RemoteClaude` SPEC section 11.4 for the full
  threat-model discussion.
- `gh release download` (used by the Claude Code path) and the
  launcher's anonymous GitHub API access (used by Claude Desktop)
  both depend on the publishing identity of this repo. Deprovisioning
  a person from the Claude Code path is just revoking their repo
  access on github.com; the Claude Desktop path is identity-less
  (anonymous public-ish reads of Release assets), so removing access
  there means uninstalling the extension on their machine.
- No auto-promotion of in-use binaries. If the cached `tether-mcp.exe`
  is locked by a running Claude Code session, the hook tells the user
  to restart manually; the Claude Desktop launcher writes to a
  `.staging` path and atomically renames, which is allowed because
  the launcher executes before spawning the MCP.
