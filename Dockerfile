# Use a full Docker Official Python image instead of the slim runtime.
# uv is copied in as a standalone binary from the official Astral image.
ARG UV_VERSION=0.12.7
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Keep the project's existing WebUI build toolchain.
FROM node:24-bookworm-slim AS webui-builder

WORKDIR /app
COPY webui/package.json webui/package-lock.json ./webui/
WORKDIR /app/webui
RUN npm ci
COPY webui/ ./
RUN mkdir -p /app/nanobot/web && npm run build

# Full Bookworm gives native build headers and common runtime utilities.
FROM python:3.12-bookworm
COPY --from=uv /uv /uvx /bin/
COPY --from=webui-builder /usr/local /usr/local

ARG PLAYWRIGHT_VERSION=1.55.0
ARG NANOBOT_CHANNELS=discord,email,feishu,napcat,qq,telegram,websocket,wecom,weixin

# General development tools, browser automation, fonts, Office and PDF tools.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        git-lfs \
        gh \
        openssh-client \
        rsync \
        nano \
        vim \
        less \
        jq \
        yq \
        ripgrep \
        fd-find \
        tree \
        file \
        iproute2 \
        iputils-ping \
        dnsutils \
        net-tools \
        netcat-openbsd \
        socat \
        traceroute \
        lsof \
        procps \
        psmisc \
        strace \
        zip \
        unzip \
        p7zip-full \
        xz-utils \
        zstd \
        bzip2 \
        dos2unix \
        build-essential \
        pkg-config \
        cmake \
        ninja-build \
        autoconf \
        automake \
        libtool \
        libssl-dev \
        libffi-dev \
        zlib1g-dev \
        util-linux \
        ffmpeg \
        sqlite3 \
        tzdata \
        bubblewrap \
        libmagic1 \
        chromium \
        fontconfig \
        fonts-noto \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        fonts-liberation \
        libreoffice-core \
        libreoffice-common \
        libreoffice-writer \
        libreoffice-calc \
        libreoffice-impress \
        libreoffice-draw \
        poppler-utils \
        pandoc \
        ghostscript \
        qpdf && \
    npm install --global --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION}" && \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers playwright install --with-deps chromium && \
    fc-cache -f && \
    rm -rf /var/lib/apt/lists/* /root/.npm

WORKDIR /app

ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:$PATH"
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
ENV NANOBOT_RUN_AS_ROOT=1

RUN uv venv --seed "$VIRTUAL_ENV"

# Install project metadata first so dependency resolution remains cacheable.
ARG NANOBOT_EXTRAS=
COPY pyproject.toml README.md LICENSE THIRD_PARTY_NOTICES.md hatch_build.py ./
RUN mkdir -p nanobot && touch nanobot/__init__.py && \
    if [ -n "$NANOBOT_EXTRAS" ]; then \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache ".[${NANOBOT_EXTRAS}]"; \
    else \
        NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
            --python "$VIRTUAL_ENV/bin/python" --no-cache .; \
    fi && \
    rm -rf nanobot

# Copy the full source and install the application.
COPY nanobot/ nanobot/
COPY scripts/install_channel_dependencies.py scripts/
COPY --from=webui-builder /app/nanobot/web/dist/ nanobot/web/dist/
RUN NANOBOT_SKIP_WEBUI_BUILD=1 uv pip install \
        --python "$VIRTUAL_ENV/bin/python" --no-cache .

# Keep common document-processing libraries available even when a future
# upstream dependency split changes the base project extras.
RUN uv pip install --python "$VIRTUAL_ENV/bin/python" --no-cache \
        "playwright==${PLAYWRIGHT_VERSION}" \
        python-docx \
        openpyxl \
        python-pptx \
        pandas \
        xlrd \
        odfpy \
        PyMuPDF \
        pypdf && \
    python -c "import docx, fitz, odf, openpyxl, pandas, playwright, pptx, xlrd"

# Preinstall the selected channel dependencies from their manifests.
RUN for channel in $(printf '%s' "$NANOBOT_CHANNELS" | tr ',' ' '); do \
        python -m scripts.install_channel_dependencies "$channel"; \
    done

# Render deploy template remains part of the official flow.
COPY render-config.json ./

# Keep the official non-root user available as an opt-out.
RUN useradd -m -u 1000 -s /bin/bash nanobot && \
    mkdir -p /home/nanobot/.nanobot && \
    chown -R nanobot:nanobot /home/nanobot /app/.venv

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh

USER root
ENV HOME=/home/nanobot
ENV PYTHONUNBUFFERED=1
ENV PYTHONFAULTHANDLER=1

EXPOSE 18790 8765

ENTRYPOINT ["entrypoint.sh"]
CMD ["status"]
