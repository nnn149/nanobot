#!/bin/sh
dir="$HOME/.nanobot"

# Render deploy path (see render.yaml + render-config.json). Gated on Render's
# automatic RENDER=true env var so local Docker/podman usage is unaffected.
# Initializes the on-disk config from the committed template (wiring secrets via
# ${VAR} env vars, keeping runtime data on the persistent disk) and appends the
# --config flag. Logs each decision so a failed start is diagnosable in Render's
# logs.
if [ "$RENDER" = "true" ]; then
    echo "[entrypoint] Render deploy — starting as $(id)"
    mkdir -p "$dir" || echo "[entrypoint] warning: mkdir $dir failed"
    config="$dir/config.json"
    # Initialize config only when it does not already exist, so WebUI/provider
    # settings edited at runtime survive restarts. The disk persists config.json
    # across deploys; overwriting it every boot would discard those changes.
    if [ ! -f "$config" ]; then
        echo "[entrypoint] initializing $config from render-config.json"
        cp /app/render-config.json "$config" || echo "[entrypoint] warning: cp config failed"
    else
        echo "[entrypoint] existing $config found — leaving it in place"
    fi
    set -- "$@" --config "$config"
fi

# In the image-only Docker deployment, the application config is stored in the
# bind-mounted data directory. nanobot's normal defaults intentionally bind the
# gateway and WebSocket WebUI to loopback, and load_config() validates an
# existing JSON file without applying NANOBOT_* nested environment overrides.
# Apply the Docker-specific external-bind defaults before starting the gateway.
#
# NANOBOT_EXTERNAL_BIND=0 opts out and keeps nanobot's normal local-only bind.
# NANOBOT_BIND_HOST can be set to a specific interface/address.
configure_docker_bind() {
    if [ "${NANOBOT_EXTERNAL_BIND:-1}" = "0" ]; then
        return 0
    fi
    if [ "${1:-}" != "gateway" ]; then
        return 0
    fi

    bind_host="${NANOBOT_BIND_HOST:-0.0.0.0}"
    config="$dir/config.json"
    mkdir -p "$dir" || {
        echo "[entrypoint] error: cannot create $dir" >&2
        return 1
    }

    if ! NANOBOT_BIND_HOST="$bind_host" python - "$config" <<'PY'
import json
import os
import secrets
import stat
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"[entrypoint] error: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(data, dict):
        print(f"[entrypoint] error: {path} must contain a JSON object", file=sys.stderr)
        raise SystemExit(1)
else:
    data = {}

bind_host = os.environ.get("NANOBOT_BIND_HOST") or "0.0.0.0"
webui_secret = os.environ.get("NANOBOT_WEBUI_TOKEN", "").strip()

gateway = data.get("gateway")
if not isinstance(gateway, dict):
    gateway = {}
    data["gateway"] = gateway
gateway["host"] = bind_host
gateway.setdefault("port", 18790)

channels = data.get("channels")
if not isinstance(channels, dict):
    channels = {}
    data["channels"] = channels

websocket = channels.get("websocket")
if not isinstance(websocket, dict):
    websocket = {}
    channels["websocket"] = websocket
websocket.setdefault("enabled", True)
websocket["host"] = bind_host
websocket.setdefault("port", 8765)
websocket["websocketRequiresToken"] = True

# A wildcard WebSocket listener must have an authentication mechanism. Prefer
# an operator-supplied secret; otherwise generate one once and persist it.
if webui_secret:
    websocket["tokenIssueSecret"] = webui_secret
else:
    token = websocket.get("token")
    issue_secret = websocket.get("tokenIssueSecret")
    if not isinstance(issue_secret, str) or not issue_secret.strip():
        legacy_issue_secret = websocket.get("token_issue_secret")
        if isinstance(legacy_issue_secret, str) and legacy_issue_secret.strip():
            websocket["tokenIssueSecret"] = legacy_issue_secret
            issue_secret = legacy_issue_secret
    has_token = isinstance(token, str) and bool(token.strip())
    has_issue_secret = isinstance(issue_secret, str) and bool(issue_secret.strip())
    trusted_proxy = websocket.get("trustedProxyAuth")
    if not (has_token or has_issue_secret or isinstance(trusted_proxy, dict) and bool(trusted_proxy)):
        websocket["tokenIssueSecret"] = secrets.token_urlsafe(32)
        print(
            f"[entrypoint] generated WebUI tokenIssueSecret in {path}",
            file=sys.stderr,
        )

new_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
old_text = None
if path.exists():
    try:
        old_text = path.read_text(encoding="utf-8")
    except OSError:
        old_text = None

if new_text != old_text:
    try:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=str(path.parent),
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(new_text)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp_name, mode)
            os.replace(temp_name, path)
        finally:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass
    except OSError as exc:
        print(f"[entrypoint] error: cannot write {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
PY
    then
        echo "[entrypoint] error: cannot prepare Docker bind configuration" >&2
        return 1
    fi
}

if ! configure_docker_bind "$@"; then
    exit 1
fi

# The toolbox image deliberately runs the agent as root by default, so skills
# can use system tooling and install task-local dependencies. Set
# NANOBOT_RUN_AS_ROOT=0 to retain the upstream nanobot-user privilege boundary.
if [ "$(id -u)" = "0" ]; then
    if [ "${NANOBOT_RUN_AS_ROOT:-1}" = "0" ]; then
        chown -R nanobot:nanobot "$dir" 2>/dev/null || echo "[entrypoint] warning: chown $dir failed"
        if setpriv --reuid=nanobot --regid=nanobot --init-groups true 2>/dev/null; then
            echo "[entrypoint] NANOBOT_RUN_AS_ROOT=0 — dropping privileges to nanobot"
            exec setpriv --reuid=nanobot --regid=nanobot --init-groups nanobot "$@"
        fi
        echo "[entrypoint] error: requested non-root mode but setpriv failed" >&2
        exit 1
    fi

    echo "[entrypoint] running as root (set NANOBOT_RUN_AS_ROOT=0 for non-root mode)"
    exec nanobot "$@"
fi

# Already non-root: make sure the data dir is writable before starting.
if [ -d "$dir" ] && [ ! -w "$dir" ]; then
    owner_uid=$(stat -c %u "$dir" 2>/dev/null || stat -f %u "$dir" 2>/dev/null)
    cat >&2 <<EOF
Error: $dir is not writable (owned by UID $owner_uid, running as UID $(id -u)).

Fix (pick one):
  Host:   sudo chown -R 1000:1000 ~/.nanobot
  Docker: docker run --user \$(id -u):\$(id -g) ...
  Podman: podman run --userns=keep-id ...
EOF
    exit 1
fi

exec nanobot "$@"
