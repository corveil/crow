# Security Policy

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security vulnerability in Crow, please report it privately through [GitHub's private vulnerability reporting](https://github.com/corveil/crow/security/advisories/new) for this repository. Include as much detail as possible:

- A description of the vulnerability
- Steps to reproduce the issue
- Affected components and potential impact

## Scope

### In Scope

- The Crow macOS application
- The `crow` CLI
- IPC socket protocol and internal packages

### Out of Scope

The following components are maintained by other projects. Please report vulnerabilities directly to them:

- **xterm.js terminal** — [xtermjs/xterm.js](https://github.com/xtermjs/xterm.js)
- **Claude Code** — [Anthropic](https://www.anthropic.com/responsible-disclosure-policy)
- **GitHub CLI (`gh`)** / **GitLab CLI (`glab`)** — Their respective maintainers

## Disclosure Policy

We ask that you practice responsible disclosure:

- Allow us reasonable time to investigate and address the issue before any public disclosure
- Make a good-faith effort to avoid privacy violations, data destruction, and service disruption during your research
- Do not publicly disclose the vulnerability until a fix has been released or 90 days have passed since your initial report, whichever comes first
