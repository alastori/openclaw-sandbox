# Learnings

Known issues and lessons. Read this at session startup to avoid repeating mistakes.

## Known Acceptable Findings

### ClawSec skill flagged by security audit (expected)
- **Date:** 2026-03-25
- **What:** `openclaw security audit --deep` flags clawsec-suite as containing "dangerous code patterns" (shell execution, environment variable access).
- **Why it's OK:** ClawSec is a security tool that needs shell access to verify file permissions, check checksums, and run integrity audits. This is expected behavior, not a vulnerability.
- **Action:** Exclude this from security audit notifications. It is expected behavior.

### Gateway binds to 0.0.0.0 inside Docker (expected)
- **Date:** 2026-03-25
- **What:** Logs show the gateway binding to `0.0.0.0` (non-loopback). Security audit may flag this as exposed to the network.
- **Why it's OK:** Docker requires the container to bind on `0.0.0.0` for port forwarding to work. The `docker-compose.yml` maps this to `127.0.0.1` on the host side, so it is not exposed to the network. This is the intended configuration.
- **Action:** Skip this in audit reports. The host-side binding is restricted to 127.0.0.1 and is safe.

### Ollama models flagged as "unsafe without sandbox" (expected)
- **Date:** 2026-03-25 (re-confirmed 2026-06-17 for `ollama/qwen3.6:35b-a3b-q8_0` and `ollama/nemotron-3-super:120b-a12b-q4_K_M`)
- **What:** Security audit flags local Ollama models as unsafe because they run with web tools enabled and no sandbox. Applies to any `ollama/*` model in `defaults/models.policy.json`, including newly added ones.
- **Why it's OK:** Web tools (`web_search`, `web_fetch`, `browser_navigate`) are denied for all Ollama models via `tools.byProvider.ollama.deny` in `defaults/security.json`. The deny is provider-scoped, so it covers every current and future `ollama/*` model automatically. The audit does not check tool deny rules; it only sees the model is configured. The actual risk is mitigated.
- **Action:** Before reporting an Ollama sandbox or web-tools finding, verify `tools.byProvider.ollama.deny` includes `web_search`, `web_fetch`, and `browser_navigate`. If those denies are present, exclude all `ollama/*` models from "web tools enabled" or "needs sandboxing" findings. Report only if the provider-scoped deny rule is missing or incomplete.
