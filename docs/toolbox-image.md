# ARM64 toolbox image

The `toolbox-arm64` branch is the maintained deployment branch for a complete
nanobot agent workbench. It is intentionally separate from `main`: keep
`main` as the easy-to-sync upstream fork branch, then merge it into this
branch when you want to publish a refreshed image.

The published image is:

```text
ghcr.io/nnn149/nanobot:toolbox-arm64
```

Every successful build also publishes a rollback tag in the form
`toolbox-arm64-<short-commit-sha>`. The image is **linux/arm64 only**.

## Included capabilities

- Full `python:3.12-bookworm` base with `uv`, Node.js, `npm`, `npx`,
  Corepack, Git/Git LFS/GitHub CLI, build tooling, search/editing tools,
  archive utilities, diagnostics, networking tools, SQLite, and FFmpeg.
- Debian Chromium for direct scripts plus Playwright's bundled Chromium, pinned
  to the installed Node and Python Playwright version.
- `fontconfig`, Noto, Noto CJK, Noto Color Emoji, and Liberation fonts for
  Chinese pages, document rendering, and screenshots.
- LibreOffice Writer/Calc/Impress/Draw for headless Office conversion, plus
  `poppler-utils`, Pandoc, Ghostscript, and QPDF for PDF/document work.
- Python document/data APIs: `python-docx`, `openpyxl`,
  `python-pptx`, `pandas`, `xlrd`, `odfpy`, PyMuPDF, and Playwright.

The image is deliberately large: full Debian, LibreOffice, two browser
installations, fonts, and development tools trade download size for an
immediately useful agent environment.

## Deploy without cloning or building

On the ARM64 host, download the image-only Compose file once:

```sh
mkdir -p nanobot-toolbox && cd nanobot-toolbox
curl -fsSLO https://raw.githubusercontent.com/nnn149/nanobot/toolbox-arm64/docker-compose.toolbox.yml
mkdir -p data
docker compose -f docker-compose.toolbox.yml pull
docker compose -f docker-compose.toolbox.yml up -d
```

The default persistent directory is `./data`. To use another location or an
immutable rollback image, create a local `.env` file beside the Compose file:

```dotenv
NANOBOT_DATA_DIR=/srv/nanobot/data
NANOBOT_IMAGE=ghcr.io/nnn149/nanobot:toolbox-arm64-<short-commit-sha>
NANOBOT_MEMORY_LIMIT=3G
NANOBOT_CPU_LIMIT=2
NANOBOT_SHM_SIZE=1gb
```

The API service is opt-in so the normal command launches only the gateway:

```sh
docker compose -f docker-compose.toolbox.yml --profile api up -d
docker compose -f docker-compose.toolbox.yml --profile cli run --rm nanobot-cli
```

To update to the latest stable toolbox tag:

```sh
docker compose -f docker-compose.toolbox.yml pull
docker compose -f docker-compose.toolbox.yml up -d
```

If the GHCR package is private, authenticate the target host with
`docker login ghcr.io` first. Make the package public in its GitHub Package
settings if unauthenticated pulls are desired.

## Runtime and browser safety

The toolbox entrypoint runs as **root by default**, as requested for broad
system-tool access. Files created in the bind-mounted data directory can
therefore become root-owned on the host. To use the original nanobot UID 1000
boundary instead, set this in `.env`:

```dotenv
NANOBOT_RUN_AS_ROOT=0
```

The Compose file intentionally does not grant `privileged` mode, a Docker
socket, or broad host mounts. Root inside a container is still unsuitable as a
security boundary for untrusted browser targets or hostile Office documents.
The image includes a `pwuser` account for explicitly lower-privilege browser
commands, for example:

```sh
docker compose -f docker-compose.toolbox.yml exec --user pwuser nanobot-gateway \
  chromium --headless --disable-gpu --screenshot=/tmp/page.png https://example.com
```

A production untrusted-browsing setup should additionally use an appropriate
Chromium seccomp/sandbox policy or an isolated browser worker.

## Verify the pulled image

```sh
docker compose -f docker-compose.toolbox.yml run --rm --entrypoint sh nanobot-cli -lc \
  'id -u; node --version; npm --version; uv --version; chromium --version; \
   playwright --version; libreoffice --headless --version; ffmpeg -version'
```

Examples of document tools available inside the image:

```sh
libreoffice --headless --convert-to pdf report.docx --outdir /tmp
pdftotext report.pdf -
pandoc report.docx -o report.md
qpdf --check report.pdf
```

## Refresh from upstream

1. Use GitHub's **Sync fork** action to update `main` from
   `HKUDS/nanobot`.
2. Open a pull request from `main` into `toolbox-arm64`.
3. Resolve any changes in `Dockerfile` or `entrypoint.sh` while retaining
   the toolbox behavior, then merge it.
4. The ARM64 publishing workflow runs and updates
   `ghcr.io/nnn149/nanobot:toolbox-arm64`.
5. On the target host, run the pull and up commands above.

This keeps all custom deployment files isolated to the custom branch:
`docker-compose.toolbox.yml`, `.github/workflows/publish-toolbox-arm64.yml`,
and this document.
