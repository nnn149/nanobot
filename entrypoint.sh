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
