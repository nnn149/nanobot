# Agent-toolbox runtime maintained on the toolbox-arm64 branch.
# Keep the application base on the full Debian Bookworm Python image, and copy
# uv in as a standalone binary so the runtime remains easy to inspect and extend.
ARG UV_VERSION=0.12.7
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM node:24-bookworm-slim AS webui-builder

WORKDIR /app
COPY webui/package.json webui/package-lock.json ./webui/
WORKDIR /app/webui
RUN npm ci
COPY webui/ ./
RUN mkdir -p /app/nanobot/web && npm run build

FROM python:3.12-bookworm

ARG PLAYWRIGHT_VERSION=1.62.0

# A practical base for skills and scripts: development, network, media,
# browser automation, and document-processing tools. Chromium is intentionally
# installed twice: the Debian binary is available to arbitrary scripts, while
# Playwright's bundled Chromium stays matched to its automation package.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bash-completion \
        bubblewrap \
        build-essential \
        bzip2 \
        ca-certificates \
        cmake \
        chromium \
        curl \
        dnsutils \
        dos2unix \
        fd-find \
        ffmpeg \
        file \
        fontconfig \
        fonts-liberation \
        fonts-noto \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        ghostscript \
        gh \
        git \
        git-lfs \
        iproute2 \
        iputils-ping \
        jq \
        less \
        libffi-dev \
        libmagic1 \
        libssl-dev \
        libtool \
        libreoffice-calc \
        libreoffice-common \
        libreoffice-core \
        libreoffice-draw \
        libreoffice-impress \
        libreoffice-writer \
        lsof \
        nano \
        net-tools \
        netcat-openbsd \
        ninja-build \
        openssh-client \
        pandoc \
        p7zip-full \
        pkg-config \
        poppler-utils \
        procps \
        psmisc \
        qpdf \
        ripgrep \
        rsync \
        socat \
        sqlite3 \
        strace \
        traceroute \
        tree \
        tzdata \
        unzip \
        vim \
        wget \
        xz-utils \
        yq \
        zip \
        zlib1g-dev \
        zstd; \
    fc-cache -f; \
    rm -rf /var/lib/apt/lists/*

# uv stays independent from the Python base image, while this copies Node.js,
# npm, npx, and corepack from the same Node version used to build the Web UI.
COPY --from=uv /uv /uvx /bin/
COPY --from=webui-builder /usr/local /usr/local

ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers

RUN set -eux; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    npm install --global --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION}"; \
    playwright install --with-deps chromium; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version; \
    npx --version; \
    playwright --version; \
    chromium --version; \
    ffmpeg -version; \
    libreoffice --headless --version

WORKDIR /app

# Keep the runtime environment writable by the optional non-root nanobot user.
# Enabled channels may install their manifest-declared dependencies at startup.
ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:$PATH"
RUN uv venv --seed "$VIRTUAL_ENV"

# Install Python dependencies first (cached layer). Hatch reads the custom build
# hook from hatch_build.py even for this metadata-only install.
ARG NANOBOT_EXTRAS=
COPY pyproject.toml README.md LICENSE THIRD_PARTY_NOTICES.md hatch_build.py ./
RUN mkdir -p nanobot && touch nanobot/__init__.py && \
    if [ -n "$NANOBOT_EXTRAS" ]; then \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache ".[$NANOBOT_EXTRAS]"; \
    else \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache .; \
    fi && \
    rm -rf nanobot

# Copy the full source and install.
COPY nanobot/ nanobot/
COPY scripts/install_channel_dependencies.py scripts/
COPY --from=webui-builder /app/nanobot/web/dist/ nanobot/web/dist/
RUN NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install --python "$VIRTUAL_ENV/bin/python" --no-cache .

# python-docx, openpyxl, and python-pptx are application dependencies. These
# additions complete the toolbox with browser automation, data, legacy Excel,
# ODF, and PDF APIs.
RUN uv pip install --python "$VIRTUAL_ENV/bin/python" --no-cache \
        "playwright==${PLAYWRIGHT_VERSION}" \
        "pandas>=2.2,<3" \
        "xlrd>=2.0,<3" \
        "odfpy>=1.4,<2" \
        "PyMuPDF>=1.25,<2" && \
    python -c "import docx, fitz, odf, openpyxl, pandas, playwright, pptx, xlrd"

# Preinstall selected channel dependencies from their manifests. A comma-separated
# list keeps the image configurable while preserving WhatsApp in the default image.
ARG NANOBOT_CHANNELS=whatsapp
RUN for channel in $(printf '%s' "$NANOBOT_CHANNELS" | tr ',' ' '); do \
        python -m scripts.install_channel_dependencies "$channel"; \
    done

# Render deploy template. It is copied into the mounted config directory only
# when RENDER=true and no config file already exists.
COPY render-config.json ./

# nanobot remains available as an opt-in non-root runtime (NANOBOT_RUN_AS_ROOT=0).
# pwuser is available for explicitly separated browser commands; do not rely on
# it as a Chromium sandbox without an appropriate Docker seccomp profile.
RUN useradd -m -u 1000 -s /bin/bash nanobot && \
    useradd -m -u 1001 -s /bin/bash pwuser && \
    mkdir -p /home/nanobot/.nanobot && \
    chown -R nanobot:nanobot /home/nanobot /app/.venv && \
    chmod -R a+rX /opt/pw-browsers

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# The toolbox image deliberately defaults to root so agents can use its system
# tools and install task-local dependencies. Set NANOBOT_RUN_AS_ROOT=0 to retain
# the upstream nanobot-user privilege drop.
USER root
ENV HOME=/home/nanobot
ENV NANOBOT_RUN_AS_ROOT=1
ENV PYTHONUNBUFFERED=1 PYTHONFAULTHANDLER=1
EXPOSE 18790 8765
ENTRYPOINT ["entrypoint.sh"]
CMD ["status"]
