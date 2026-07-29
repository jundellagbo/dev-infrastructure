#!/usr/bin/env bash

# Delete a project and its nginx vhost

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DOMAIN_SUFFIX="dev.local"

. "${INFRA_DIR}/platforms/platform.sh"

# A .env written on Windows carries CRLF; a trailing \r inside the path would
# make every -f and -d test below miss.
read_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "${INFRA_DIR}/.env" | tr -d '\r' | tail -n 1
}

if [ -f "${INFRA_DIR}/.env" ]; then
    WWW_PATH="${WWW_PATH:-$(read_env_value WWW_PATH)}"
    NGINX_PATH="${NGINX_PATH:-$(read_env_value NGINX_PATH)}"
fi

resolve_host_path() {
    case "$1" in
        /*|[A-Za-z]:[/\\]*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "${INFRA_DIR}/${1#./}" ;;
    esac
}

WWW_PATH="$(resolve_host_path "${WWW_PATH:-./www}")"
NGINX_PATH="$(resolve_host_path "${NGINX_PATH:-./nginx}")"

usage() {
    echo "Usage: $0 <project-name> [--keep-files]"
    echo ""
    echo "Deletes a project's nginx configuration and optionally its files."
    echo ""
    echo "Options:"
    echo "  --keep-files    Keep the www directory (only remove nginx config)"
    echo ""
    echo "Example:"
    echo "  $0 myapp"
    echo "  $0 myapp --keep-files"
    echo ""
    exit 1
}

if [ -z "${1:-}" ]; then
    usage
fi

PROJECT_NAME="$1"
KEEP_FILES=false

if [ "${2:-}" = "--keep-files" ]; then
    KEEP_FILES=true
fi

FULL_DOMAIN="${PROJECT_NAME}.${DOMAIN_SUFFIX}"
NGINX_CONF="${NGINX_PATH}/${FULL_DOMAIN}.conf"
WWW_DIR="${WWW_PATH}/${FULL_DOMAIN}"
HOSTS_FILE="$(platform_hosts_file)"

infra_banner "Deleting Project: ${FULL_DOMAIN}"

# Check if project exists
if [ ! -f "$NGINX_CONF" ] && [ ! -d "$WWW_DIR" ]; then
    infra_err "Project not found: ${FULL_DOMAIN}"
    exit 1
fi

# Confirm deletion
printf '%bThis will delete:%b\n' "$INFRA_YELLOW" "$INFRA_NC"
[ -f "$NGINX_CONF" ] && echo "  - $NGINX_CONF"
if [ "$KEEP_FILES" = false ] && [ -d "$WWW_DIR" ]; then
    echo "  - $WWW_DIR (and all contents)"
fi
echo ""
# The prompt is printed separately rather than through `read -p`: -p is not in
# POSIX read, and zsh - which is what a macOS user may well pipe this through -
# spells the same thing differently.
printf 'Are you sure? (y/N) '
read -r REPLY
echo ""

case "$REPLY" in
    [yY]|[yY][eE][sS]) ;;
    *) infra_info "Cancelled"; exit 0 ;;
esac

# Remove nginx configuration
if [ -f "$NGINX_CONF" ]; then
    infra_info "Removing nginx configuration..."
    rm -f "$NGINX_CONF"
    infra_ok "Removed ${NGINX_CONF}"
fi

# Remove www directory
if [ "$KEEP_FILES" = false ] && [ -d "$WWW_DIR" ]; then
    infra_info "Removing www directory..."
    # Containers write into the bind mount as root, so a plain rm can hit files
    # this user doesn't own. Escalate rather than reporting a delete that only
    # half happened - and where there is no way to escalate, say what is left.
    if ! rm -rf "$WWW_DIR" 2>/dev/null; then
        platform_sudo rm -rf "$WWW_DIR" || true
    fi
    if [ -d "$WWW_DIR" ]; then
        infra_warn "Could not fully remove ${WWW_DIR} - remove it by hand"
    else
        infra_ok "Removed ${WWW_DIR}"
    fi
elif [ -d "$WWW_DIR" ]; then
    infra_warn "Keeping www directory: ${WWW_DIR}"
fi

# Check if hosts entry exists
if grep -q "${FULL_DOMAIN}" "$HOSTS_FILE" 2>/dev/null; then
    infra_warn "A hosts entry is left behind - to remove it:"
    infra_note "$(platform_hosts_remove_hint "$FULL_DOMAIN")"
fi

# Reload nginx if running
infra_info "Reloading nginx..."
if platform_docker exec infra-nginx nginx -t 2>/dev/null; then
    if platform_docker exec infra-nginx nginx -s reload 2>/dev/null; then
        infra_ok "Nginx reloaded"
    else
        infra_warn "Could not reload nginx"
    fi
else
    infra_warn "Nginx not running or configuration issue"
fi

infra_banner "Project Deleted Successfully!" "$INFRA_GREEN"
