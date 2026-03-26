#!/usr/bin/env python3
"""Resolve secrets from a pluggable backend into env vars or files.

Reads config/secrets-mapping.yaml, resolves each secret via the configured
backend (1Password, Vault, AWS SM, Keychain, or env), and outputs a .env
file for Docker Compose injection.

Usage:
  resolve-secrets.py                     # Resolve and write .runtime/openclaw.env
  resolve-secrets.py --dry-run           # Preview without writing
  resolve-secrets.py --validate          # Check all secrets can be resolved
  resolve-secrets.py --backend env       # Override backend (ignore mapping file)

The mapping file (config/secrets-mapping.yaml) is per-user and gitignored.
Copy from templates/secrets-mapping.yaml.template to get started.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    # Fallback: pip install pyyaml not available — use simple parser
    yaml = None

ROOT_DIR = Path(__file__).resolve().parent.parent
MAPPING_FILE = ROOT_DIR / "config" / "secrets-mapping.yaml"
MAPPING_TEMPLATE = ROOT_DIR / "templates" / "secrets-mapping.yaml.template"
BACKENDS_FILE = ROOT_DIR / "defaults" / "secrets-backend.json"
OUTPUT_FILE = ROOT_DIR / ".runtime" / "openclaw.env"


def load_yaml_simple(path):
    """Minimal YAML-like parser for key: value files when PyYAML isn't available."""
    result = {}
    current_section = None
    current_item = None
    with open(path) as f:
        for line in f:
            stripped = line.rstrip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            content = stripped.strip()
            if ":" in content:
                key, _, value = content.partition(":")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if indent == 0:
                    if value:
                        result[key] = value
                    else:
                        current_section = key
                        result[current_section] = {}
                        current_item = None
                elif indent <= 4 and current_section:
                    if value:
                        result[current_section][key] = value
                    else:
                        current_item = key
                        result[current_section][current_item] = {}
                elif indent > 4 and current_section and current_item:
                    result[current_section][current_item][key] = value
    return result


def load_mapping():
    """Load the secrets mapping file."""
    if not MAPPING_FILE.exists():
        print(f"No mapping file at {MAPPING_FILE}")
        print(f"Copy from: {MAPPING_TEMPLATE}")
        sys.exit(1)

    if yaml:
        with open(MAPPING_FILE) as f:
            return yaml.safe_load(f)
    else:
        return load_yaml_simple(MAPPING_FILE)


def load_backends():
    """Load backend definitions."""
    with open(BACKENDS_FILE) as f:
        return json.load(f)


def resolve_1password(ref, service_account_keychain=None):
    """Resolve a secret via 1Password CLI."""
    env = os.environ.copy()
    if service_account_keychain and "OP_SERVICE_ACCOUNT_TOKEN" not in env:
        try:
            token = subprocess.run(
                ["security", "find-generic-password", "-a", service_account_keychain,
                 "-s", "1password-service-account", "-w"],
                capture_output=True, text=True, timeout=5,
            )
            if token.returncode == 0 and token.stdout.strip():
                env["OP_SERVICE_ACCOUNT_TOKEN"] = token.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    try:
        result = subprocess.run(
            ["op", "read", ref],
            capture_output=True, text=True, timeout=10, env=env,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def resolve_vault(path, field):
    """Resolve a secret via HashiCorp Vault CLI."""
    try:
        result = subprocess.run(
            ["vault", "kv", "get", f"-field={field}", path],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def resolve_aws_sm(ref):
    """Resolve a secret via AWS Secrets Manager CLI."""
    try:
        result = subprocess.run(
            ["aws", "secretsmanager", "get-secret-value",
             "--secret-id", ref, "--query", "SecretString", "--output", "text"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def resolve_keychain(account, service="openclaw"):
    """Resolve a secret from macOS Keychain."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", account, "-s", service, "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def resolve_env(env_var):
    """Resolve from environment variable."""
    return os.environ.get(env_var)


def resolve_secret(entry, backend, op_config=None):
    """Resolve a single secret entry using the configured backend."""
    ref = entry.get("ref", "")
    env_fallback = entry.get("env_fallback", "")

    value = None

    if backend == "1password" and ref:
        keychain = (op_config or {}).get("service_account_keychain")
        value = resolve_1password(ref, keychain)
    elif backend == "vault" and ref:
        # Parse "secret/path#field" format
        if "#" in ref:
            path, field = ref.rsplit("#", 1)
        else:
            path, field = ref, "value"
        value = resolve_vault(path, field)
    elif backend == "aws-sm" and ref:
        value = resolve_aws_sm(ref)
    elif backend == "keychain" and ref:
        value = resolve_keychain(ref)

    # Fallback to env var
    if not value and env_fallback:
        value = resolve_env(env_fallback)

    return value


def collect_secrets(mapping):
    """Collect all secret entries from the mapping."""
    backend = mapping.get("backend", "env")
    op_config = mapping.get("onepassword", {})
    entries = []

    for section_key in ["platform", "providers"]:
        section = mapping.get(section_key, {})
        if not isinstance(section, dict):
            continue
        for secret_id, entry in section.items():
            if not isinstance(entry, dict):
                continue
            entries.append({
                "id": secret_id,
                "section": section_key,
                "env_var": entry.get("env_fallback", ""),
                "ref": entry.get("ref", ""),
                "required": entry.get("required", False),
                "description": entry.get("description", ""),
                "entry": entry,
            })

    # Tool pack sections (pack:*)
    for key, section in mapping.items():
        if key.startswith("pack:") and isinstance(section, dict):
            for secret_id, entry in section.items():
                if not isinstance(entry, dict):
                    continue
                entries.append({
                    "id": secret_id,
                    "section": key,
                    "env_var": entry.get("env_fallback", ""),
                    "ref": entry.get("ref", ""),
                    "required": entry.get("required", False),
                    "description": entry.get("description", ""),
                    "entry": entry,
                })

    return entries, backend, op_config


def main():
    dry_run = "--dry-run" in sys.argv
    validate_only = "--validate" in sys.argv
    backend_override = None
    for i, arg in enumerate(sys.argv):
        if arg == "--backend" and i + 1 < len(sys.argv):
            backend_override = sys.argv[i + 1]

    mapping = load_mapping()
    entries, backend, op_config = collect_secrets(mapping)

    if backend_override:
        backend = backend_override

    print(f"Backend: {backend}")
    print(f"Secrets: {len(entries)} declared")
    print()

    resolved = {}
    failures = []

    for entry in entries:
        value = resolve_secret(entry["entry"], backend, op_config)
        env_var = entry["env_var"]

        if value and env_var:
            resolved[env_var] = value
            status = "OK"
        elif not value and entry["required"]:
            failures.append(entry)
            status = "MISSING (required)"
        elif not value:
            status = "MISSING (optional)"
        else:
            status = "OK (no env var mapped)"

        if dry_run or validate_only:
            masked = value[:4] + "..." + value[-4:] if value and len(value) > 12 else ("***" if value else "—")
            print(f"  [{status:20s}] {entry['id']:30s} → {env_var or '(none)':30s} = {masked}")

    print()

    if failures:
        print(f"FAILED: {len(failures)} required secret(s) could not be resolved:")
        for f in failures:
            print(f"  - {f['id']}: {f['description']}")
        if not dry_run:
            sys.exit(1)

    if validate_only:
        print(f"Validation: {len(resolved)} resolved, {len(failures)} failed")
        return 0

    if dry_run:
        print(f"Dry run: would write {len(resolved)} env vars to {OUTPUT_FILE}")
        return 0

    # Write .runtime/openclaw.env
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    # Load existing non-secret env vars (COMPOSE_PROJECT_NAME, OPENCLAW_PORT, etc.)
    instance_env = {}
    instance_file = ROOT_DIR / ".env.instance.local"
    if instance_file.exists():
        for line in instance_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                instance_env[k.strip()] = v.strip()

    # Write atomically
    import tempfile
    fd, tmp_path = tempfile.mkstemp(dir=OUTPUT_FILE.parent, suffix=".env")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("# Auto-generated by resolve-secrets.py — do not edit\n")
            f.write(f"# Backend: {backend}\n")
            f.write(f"# Secrets: {len(resolved)} resolved\n\n")
            for k, v in sorted(resolved.items()):
                # Shell-safe quoting
                if any(c in v for c in " '\"$`\\"):
                    f.write(f"{k}='{v}'\n")
                else:
                    f.write(f"{k}={v}\n")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, OUTPUT_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise

    print(f"Wrote {len(resolved)} secrets to {OUTPUT_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
