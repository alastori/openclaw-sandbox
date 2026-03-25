# Learnings

Known issues and lessons. Read this at session startup to avoid repeating mistakes.

## Known Acceptable Findings

### ClawSec skill flagged by security audit (expected)
- **Date:** 2026-03-25
- **What:** `openclaw security audit --deep` flags clawsec-suite as containing "dangerous code patterns" (shell execution, environment variable access).
- **Why it's OK:** ClawSec is a security tool that needs shell access to verify file permissions, check checksums, and run integrity audits. This is expected behavior, not a vulnerability.
- **Action:** Exclude this from security audit notifications — it is expected behavior.

### Gateway binds to 0.0.0.0 inside Docker (expected)
- **Date:** 2026-03-25
- **What:** Logs show the gateway binding to `0.0.0.0` (non-loopback). Security audit may flag this as exposed to the network.
- **Why it's OK:** Docker requires the container to bind on `0.0.0.0` for port forwarding to work. The `docker-compose.yml` maps this to `127.0.0.1` on the host side, so it is NOT exposed to the network. This is the intended configuration.
- **Action:** Skip this in audit reports — the host-side binding is restricted to 127.0.0.1 and is safe.

### Ollama models flagged as "unsafe without sandbox" (expected)
- **Date:** 2026-03-25
- **What:** Security audit flags local Ollama models as unsafe because they run with web tools enabled and no sandbox.
- **Why it's OK:** Web tools (web_search, web_fetch, browser_navigate) are denied for Ollama models via `tools.byProvider.ollama.deny` in `defaults/security.json`. The audit does not check tool deny rules — it only sees the model is configured. The actual risk is mitigated.
- **Action:** Note the deny rules are in place and skip this in audit reports — the risk is mitigated.
