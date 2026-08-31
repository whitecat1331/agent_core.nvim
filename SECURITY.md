# Security Policy

## Supported versions

We support the latest release and the `main` branch. Older versions do not
receive security fixes.

| Version | Supported          |
|---------|--------------------|
| 0.1.x   | :white_check_mark: |
| main    | :white_check_mark: |

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

1. Open a **private vulnerability report** via GitHub:
   **Security → Report a vulnerability** (the *Advisories* tab), or
2. Email the maintainer (see the git history / profile for contact details).

Please include:

- A description of the vulnerability and its impact.
- Steps to reproduce, or a proof of concept.
- Affected versions and any known mitigations.

We will acknowledge within 3 business days and aim to publish a fix within 30
days. We may publish a security advisory (GHSA) once a fix is available.

## Security model

This plugin is a client-side Neovim orchestrator. Key properties:

- **No secrets in source.** API keys are resolved env-first and never committed.
  The fallback store (`agent_keys.json`) is written `0600` and gitignored.
- **No file-content exfiltration.** The generated project brief (`AVANTE.md`)
  is structural only (paths, language counts, key files, build/test commands);
  it never embeds file contents, so it cannot leak secrets into the chat
  context.
- **No network egress outside the owned provider transport.** `agent_core` makes
  HTTP requests only through its owned streaming transport (`agent_core.runtime.transport`)
  to the configured LLM providers, and through `mcphub.nvim` MCP servers.
- **Per-project opt-in.** `semnav` (a local semantic-graph MCP server) is only
  registered for a repo after the user runs `:AgentIndex`; its daemon is stopped
  on `VimLeavePre`.

## Automated scanning

CI runs a defense-in-depth pipeline on every push and PR:

- `gitleaks` (full-history secret scan)
- `detect-secrets` (baseline-diff secret scan)
- Semgrep (`p/lua`, `p/secrets`, `p/security-audit`) — report-only
- `stylua` + `selene` (static lint)
- `actionlint` (workflow validation)

CodeQL is intentionally not enabled: CodeQL has no Lua extractor, so there is
nothing for it to analyze. The scans above substitute for it.
