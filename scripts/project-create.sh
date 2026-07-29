#!/usr/bin/env bash

# Create a new project served by the automatic nginx vhost

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DOMAIN_SUFFIX="dev.local"

. "${INFRA_DIR}/platforms/platform.sh"

# A .env written on Windows carries CRLF, and a trailing \r would end up inside
# the path - a directory whose name ends in a carriage return is a bad afternoon.
read_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "${INFRA_DIR}/.env" | tr -d '\r' | tail -n 1
}

if [ -f "${INFRA_DIR}/.env" ]; then
    WWW_PATH="${WWW_PATH:-$(read_env_value WWW_PATH)}"
fi

resolve_host_path() {
    case "$1" in
        # Absolute in either notation: /srv/www under a Unix shell, C:/... or
        # //server/share when the .env points at a Windows-side directory.
        /*|[A-Za-z]:[/\\]*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "${INFRA_DIR}/${1#./}" ;;
    esac
}

WWW_PATH="$(resolve_host_path "${WWW_PATH:-./www}")"

ensure_host_dns() {
    local domain="$1" hosts entry="127.0.0.1 ${1}"
    hosts="$(platform_hosts_file)"

    if infra_resolves_loopback "infra-host-dns-check.${DOMAIN_SUFFIX}"; then
        infra_ok "Wildcard host DNS already resolves *.${DOMAIN_SUFFIX}"
        return
    fi

    if grep -qF "$domain" "$hosts" 2>/dev/null; then
        infra_ok "Hosts entry already exists in ${hosts}"
        return
    fi

    infra_info "Adding hosts entry for ${domain} to ${hosts}..."
    if [ -w "$hosts" ]; then
        printf '%s\n' "$entry" >> "$hosts"
        infra_ok "Added hosts entry"
    elif command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
        if printf '%s\n' "$entry" | sudo tee -a "$hosts" >/dev/null; then
            infra_ok "Added hosts entry"
        else
            infra_warn "Could not add hosts entry"
        fi
    else
        infra_warn "Could not write ${hosts}. Add this line to it yourself:"
        infra_note "$entry"
        infra_warn "For a persistent wildcard instead of one line per project:"
        infra_note "sudo ${INFRA_DIR}/scripts/setup-host-dns.sh"
    fi

    # WSL has a second hosts file, on the side the browser actually runs on.
    if platform_windows_hosts_file >/dev/null 2>&1; then
        wsl_browser_note
    fi
}

usage() {
    echo "Usage: $0 <project-name>"
    echo ""
    echo "Creates a new project directory served by the automatic nginx vhost."
    echo ""
    echo "Example:"
    echo "  $0 myapp"
    echo "  Creates: myapp.dev.local"
    echo ""
    exit 1
}

if [ -z "${1:-}" ]; then
    usage
fi

PROJECT_NAME="$1"
FULL_DOMAIN="${PROJECT_NAME}.${DOMAIN_SUFFIX}"
WWW_DIR="${WWW_PATH}/${FULL_DOMAIN}"

infra_banner "Creating Project: ${FULL_DOMAIN}"

if [ -d "$WWW_DIR" ]; then
    infra_err "Directory already exists: $WWW_DIR"
    exit 1
fi

# Create www directory
infra_info "Creating www directory..."
mkdir -p "${WWW_DIR}/public"
infra_ok "Created ${WWW_DIR}/public"

# Create default index.php
cat > "${WWW_DIR}/public/index.php" << 'EOF'
<?php
$projectName = basename(dirname(__DIR__));
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($projectName) ?></title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: white;
            padding: 3rem;
            border-radius: 1rem;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.25);
            text-align: center;
            max-width: 500px;
        }
        h1 { color: #1a202c; margin-bottom: 1rem; }
        p { color: #718096; margin-bottom: 0.5rem; }
        .php-version {
            background: #edf2f7;
            padding: 0.5rem 1rem;
            border-radius: 0.5rem;
            display: inline-block;
            margin-top: 1rem;
            font-family: monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1><?= htmlspecialchars($projectName) ?></h1>
        <p>Your project is ready!</p>
        <p class="php-version">PHP <?= PHP_VERSION ?></p>
    </div>
</body>
</html>
EOF
infra_ok "Created index.php"

infra_ok "Automatic nginx vhost: ${FULL_DOMAIN}"
ensure_host_dns "${FULL_DOMAIN}"

infra_banner "Project Created Successfully!" "$INFRA_GREEN"
echo "Project URL: http://${FULL_DOMAIN}"
echo "Document root: ${WWW_DIR}/public"
echo ""
