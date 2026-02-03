FROM golang:1.24.2-bookworm AS go-builder
ENV GOPATH=/go
ENV PATH=$PATH:/go/bin

# Install Go tools and then clean module/build caches to avoid leaving extra data in this stage
RUN go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest && \
    go install github.com/projectdiscovery/httpx/cmd/httpx@latest && \
    go install github.com/projectdiscovery/katana/cmd/katana@latest && \
    go install github.com/projectdiscovery/naabu/v2/cmd/naabu@latest && \
    go install github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest && \
    go install github.com/ffuf/ffuf/v2@latest && \
    go install github.com/OJ/gobuster/v3@latest && \
    go install github.com/tomnomnom/waybackurls@latest && \
    go install github.com/tomnomnom/anew@latest && \
    go install github.com/zricethezav/gitleaks/v8@latest && \
    go install github.com/aquasecurity/trivy/cmd/trivy@latest && \
    go clean -modcache && rm -rf /root/.cache/go-build /tmp/* /go/pkg/mod/cache/download

FROM debian:stable-slim AS downloader
RUN apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*
WORKDIR /downloads

# Download Kiterunner, extract and remove archive
RUN wget -q https://github.com/assetnote/kiterunner/releases/download/v1.0.2/kiterunner_1.0.2_linux_amd64.tar.gz && \
    tar xzf kiterunner_1.0.2_linux_amd64.tar.gz && \
    mv kr /usr/local/bin/kr && \
    rm -f kiterunner_1.0.2_linux_amd64.tar.gz

# Download Burp Suite Community JAR (updated to 2024.x)
RUN wget -q "https://portswigger.net/burp/releases/download?product=community&version=2024.12&type=Jar" -O /downloads/burpsuite_community.jar

FROM kalilinux/kali-rolling

ARG DEBIAN_FRONTEND=noninteractive

# 1. Base System & Runtimes
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    wget \
    git \
    vim \
    zsh \
    unzip \
    jq \
    iputils-ping \
    python3-full \
    python3-pip \
    python3-venv \
    pipx \
    default-jre \
    libpcap-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# 2. Core Kali Tools (Web & Network)
RUN apt-get update && apt-get install -y --no-install-recommends \
    nmap \
    masscan \
    sqlmap \
    nikto \
    hydra \
    wafw00f \
    whatweb \
    seclists \
    zaproxy \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# 3. Report Generation Tools
# Install pandoc from apt and wkhtmltopdf from upstream .deb to avoid missing-package issues
RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# Install wkhtmltopdf from a prebuilt .deb (choose a release compatible with your base image)
# If dpkg has missing deps, fix with apt-get -f install
RUN set -eux; \
    WK_DEB="/tmp/wkhtmltopdf.deb"; \
    wget -q -O "$WK_DEB" "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.buster_amd64.deb"; \
    dpkg -i "$WK_DEB" || (apt-get update && apt-get -f install -y); \
    rm -f "$WK_DEB"; \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# 4. Copy Go Binaries
COPY --from=go-builder /go/bin/* /usr/local/bin/

# 5. Copy Downloaded Tools
COPY --from=downloader /usr/local/bin/kr /usr/local/bin/
COPY --from=downloader /downloads/burpsuite_community.jar /opt/burpsuite_community.jar

# 6. Python Tools (via pipx) including dependency scanning; clean pip cache
ENV PATH=$PATH:/root/.local/bin
RUN pipx install arjun && \
    pipx install dirsearch && \
    pipx install uro && \
    pipx install pip-audit && \
    python3 -m pip cache purge || true

# 7. Node.js and npm-audit (for JavaScript dependency scanning)
RUN apt-get update && apt-get install -y --no-install-recommends \
    nodejs \
    npm \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
    npm install -g npm-audit-html && npm cache clean --force

# 8. Create non-root user for security
RUN useradd -m -s /bin/zsh pentest && \
    mkdir -p /app /data && \
    chown -R pentest:pentest /app /data

# 9. Configuration (as root for initial setup)
WORKDIR /app
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Setup Zsh for pentest user
USER pentest
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true

# Switch back to root for entrypoint (entrypoint can drop privileges if needed)
USER root

# Ensure pentest user can access necessary directories
RUN chown -R pentest:pentest /home/pentest

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]