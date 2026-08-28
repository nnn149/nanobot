# ARM64 image

The \`arm64\` branch is based on the fork's \`main\`, which is fast-forwarded from
\`HKUDS/nanobot\` before custom changes are applied.

The GitHub Actions workflow builds and publishes:

\`\`\`text
ghcr.io/nnn149/nanobot:arm64
\`\`\`

It also publishes an immutable \`arm64-<commit>\` tag for rollback.

## Use the published image

Download the official Compose file from this branch, create the local data
directory, then pull and start the image:

\`\`\`sh
mkdir -p nanobot && cd nanobot
curl -fsSL \
  https://raw.githubusercontent.com/nnn149/nanobot/arm64/docker-compose.yml \
  -o docker-compose.yml
mkdir -p data
docker compose pull
docker compose up -d
\`\`\`

The Compose service definitions and port bindings otherwise follow upstream.
The gateway and API loopback bindings are intentionally unchanged; adjust them
manually if the service must be reachable from another machine.

The first-time configuration still follows nanobot's official onboarding flow:

\`\`\`sh
docker compose --profile cli run --rm nanobot-cli onboard
\`\`\`

This writes \`./data/config.json\`, which is mounted into the container at
\`/home/nanobot/.nanobot/config.json\`.

## Included additions

The image uses the full \`python:3.12-bookworm\` base and copies in \`uv\`. It
also includes Node.js/npm/npx, common build and network tools, FFmpeg,
Chromium, Playwright plus its Chromium browser, CJK fonts, LibreOffice,
Poppler, Pandoc, Ghostscript, qpdf, and common Python Office/document
libraries.

The default preinstalled channel dependencies are:

\`\`\`text
discord,email,feishu,napcat,qq,telegram,websocket,wecom,weixin
\`\`\`

The container runs as root by default. Set \`NANOBOT_RUN_AS_ROOT=0\` to use the
official non-root fallback.

## Sync upstream

After updating the fork's \`main\` from \`HKUDS/nanobot/main\`, merge that
updated \`main\` into \`arm64\`. Keep the custom changes limited to
\`Dockerfile\`, \`docker-compose.yml\`, \`entrypoint.sh\`, this document, and
the ARM64 workflow. Pushing \`arm64\` automatically rebuilds and republishes
the image.
