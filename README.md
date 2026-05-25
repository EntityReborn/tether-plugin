# Tether plugin marketplace

Private Claude Code marketplace for the **Tether** remote-Windows MCP
plugin. The marketplace, the plugin manifest, the SessionStart hook,
and the GitHub Releases that host `tether-mcp.exe` all live here.

The MCP server source code (Go) lives in a separate repo
(`EntityReborn/RemoteClaude`); a tagged release there builds the .exe
and uploads it here.

## Install (per tech, once)

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

## Update flow

When `EntityReborn/RemoteClaude` publishes a new release:

1. Its release CI builds `tether-mcp.exe` and `tether-mcp.exe.sha256`.
2. It creates a Release on **this** repo tagged `v<X.Y.N>` with the
   binary + sidecar as assets.
3. It pushes a commit to this repo bumping `plugins/tether/version.txt`.

End users pick up the change by running `/plugin marketplace update`
(or letting Claude Code auto-update if configured). The next session
start sees the bumped `version.txt`, sees its cached version no longer
matches, and downloads.

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

## Security posture

- Every published binary is accompanied by a SHA-256 sidecar in the
  same Release. The hook refuses to install if the hashes diverge.
- `gh release download` uses each tech's own GitHub identity. No
  shared secret on disk; deprovisioning a person is just revoking
  their repo access on github.com.
- No auto-promotion of in-use binaries (the
  `tether-mcp.exe.new`-style sidecar dance from earlier versions
  of the MCP was identified as a privilege-escalation primitive in
  the source repo's H2 review and removed). If the binary is locked
  by a running Claude Code, the user is told to restart manually.
