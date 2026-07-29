#!/usr/bin/env bash

# Fix file permissions for WordPress projects in the infra Docker environment
#
# Ownership:  www:www-data (uid 1000:gid 82)
#   - www (uid 1000) maps to the host user, so files are editable in Cursor/IDE
#   - www-data (gid 82) is the PHP-FPM process group, so WordPress can write
#
# Permissions:
#   Directories ........... 2775 (setgid: new files inherit the www-data group)
#   Files ................. 664  (owner+group rw, world-readable)
#   wp-config.php ......... 660  (owner+group rw, not world-readable)
#
# Incoming / newly created files:
#   Default ACLs are applied on the host side of the bind mount so that any
#   NEW file — created by PHP-FPM (www-data), docker exec as root, or the
#   host user in a terminal — is automatically rw for uid 1000 and gid 82,
#   regardless of the creator's umask. Requires `setfacl` on the host.
#
# WordPress config:
#   FS_METHOD ............. 'direct'  (bypass FTP prompt for plugin/theme uploads)
#
# Platforms: the in-container half runs identically everywhere. The host-side
# ACL step is Linux and WSL only - macOS and Windows bind mounts are translated
# by Docker Desktop, which presents container-side ownership of its own and has
# no setfacl to honour anyway. Everything else still applies there.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINER="infra-php"
WEB_ROOT="/var/www"

. "${INFRA_DIR}/platforms/platform.sh"

usage() {
    echo "Usage: $0 [project-name]"
    echo ""
    echo "Fix file permissions for WordPress projects."
    echo ""
    echo "Options:"
    echo "  project-name    Fix a specific project (e.g. mysite.dev.local)"
    echo "                  If omitted, all WordPress projects are fixed."
    echo ""
    echo "Examples:"
    echo "  $0                          # Fix all WordPress projects"
    echo "  $0 gogogarage.dev.local     # Fix a specific project"
    echo ""
    exit 1
}

# Show help
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

infra_require_command docker || exit 1

# Verify the PHP container is running
if ! infra_docker_running "$CONTAINER"; then
    infra_err "Container '$CONTAINER' is not running. Start it with: docker compose up -d"
    exit 1
fi

# Resolve the host-side path of the /var/www bind mount (used for ACLs, since
# the Alpine container has no setfacl — ACLs set on the host apply in-container).
# docker reports it in the host's own notation, so on Git Bash that comes back
# as C:\... and has to be converted before any -d test can see it.
HOST_WEB_ROOT=$(platform_docker inspect "$CONTAINER" \
    --format "{{range .Mounts}}{{if eq .Destination \"${WEB_ROOT}\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)
if [ -n "$HOST_WEB_ROOT" ]; then
    HOST_WEB_ROOT="$(platform_shell_path "$HOST_WEB_ROOT")"
fi

# Fix permissions for a single project (WordPress or not)
fix_project() {
    local project_path="$1"
    local project_name
    project_name=$(basename "$project_path")

    infra_banner "Fixing: ${project_name}"

    # Determine the web-accessible root (public/ subdirectory if present)
    local public_root=""
    if platform_docker exec "$CONTAINER" test -d "${project_path}/public" 2>/dev/null; then
        public_root="${project_path}/public"
    else
        public_root="$project_path"
    fi

    # Determine if this is a WordPress project
    local wp_root=""
    if platform_docker exec "$CONTAINER" test -f "${project_path}/wp-includes/version.php" 2>/dev/null; then
        wp_root="$project_path"
    elif platform_docker exec "$CONTAINER" test -f "${project_path}/public/wp-includes/version.php" 2>/dev/null; then
        wp_root="${project_path}/public"
    fi

    if [ -n "$wp_root" ]; then
        infra_info "WordPress root: ${wp_root}"
    else
        infra_info "Web root: ${public_root} (not a WordPress project — fixing base permissions)"
    fi

    # ── 1. Set ownership: www:www-data (uid 1000:gid 82) ──
    infra_info "Setting ownership to www:www-data..."
    platform_docker exec -u root "$CONTAINER" chown -R www:www-data "$project_path"
    infra_ok "Ownership set"

    # ── 2. Default ACLs so incoming files stay accessible ──
    # Default ACLs guarantee any NEW file is rw for the host user (uid 1000)
    # and PHP-FPM (gid 82) no matter who creates it or what their umask is.
    # Applied on the host side of the bind mount (container lacks setfacl).
    # Must run BEFORE the chmod step: non-root setfacl strips setgid bits.
    local host_project_path="${HOST_WEB_ROOT}/${project_name}"
    if command -v setfacl >/dev/null 2>&1 && [ -n "$HOST_WEB_ROOT" ] && [ -d "$host_project_path" ]; then
        infra_info "Applying default ACLs (new files: rw for uid 1000 + gid 82)..."
        setfacl -R -m "u:1000:rwX,g:82:rwX,o::rX" "$host_project_path"
        setfacl -R -d -m "u::rwX,g::rwX,u:1000:rwX,g:82:rwX,o::rX" "$host_project_path"
        infra_ok "Default ACLs applied"
    elif platform_uses_posix_acls; then
        infra_warn "setfacl unavailable or host path not found — skipping ACLs."
        infra_warn "  Install it (apt-get install acl) or new PHP-created files may not"
        infra_warn "  be writable from the host terminal."
    else
        # Docker Desktop's file sharing already presents everything to the host
        # as the host user, so there is nothing for an ACL to fix.
        infra_info "Skipping ACLs — Docker Desktop on $(platform_label) maps ownership for you"
    fi

    # ── 3. Base permissions: 2775 dirs (setgid), 664 files ──
    # setgid on directories makes every NEW file/dir inherit the www-data
    # group; group-writable files mean both the host user and PHP-FPM can
    # edit everything even where ACLs are unavailable.
    infra_info "Setting base permissions (dirs: 2775 setgid, files: 664)..."
    platform_docker exec -u root "$CONTAINER" find "$project_path" -type d -exec chmod 2775 {} +
    platform_docker exec -u root "$CONTAINER" find "$project_path" -type f -exec chmod 664 {} +
    infra_ok "Base permissions set"

    # Stop here for non-WordPress projects
    if [ -z "$wp_root" ]; then
        infra_ok "Done: ${project_name}"
        return 0
    fi

    # ── 4. Secure wp-config.php (660: owner+group rw, not world-readable) ──
    for config_path in "${wp_root}/wp-config.php" "${project_path}/wp-config.php"; do
        if platform_docker exec "$CONTAINER" test -f "$config_path" 2>/dev/null; then
            infra_info "Securing wp-config.php (660)..."
            platform_docker exec -u root "$CONTAINER" chmod 660 "$config_path"
            infra_ok "wp-config.php secured"
            break
        fi
    done

    # ── 5. Ensure FS_METHOD is set to 'direct' in wp-config.php ──
    # Without this, WordPress detects that file owner (www) ≠ PHP process user
    # (www-data) and asks for FTP credentials when installing plugins/themes.
    for config_path in "${project_path}/wp-config.php" "${wp_root}/wp-config.php"; do
        if platform_docker exec "$CONTAINER" test -f "$config_path" 2>/dev/null; then
            if ! platform_docker exec "$CONTAINER" grep -q "FS_METHOD" "$config_path" 2>/dev/null; then
                infra_info "Adding FS_METHOD 'direct' to wp-config.php..."
                platform_docker exec -u root "$CONTAINER" sh -c \
                    "sed -i \"/That's all, stop editing/i define('FS_METHOD', 'direct');\" '$config_path'"
                if platform_docker exec "$CONTAINER" grep -q "FS_METHOD" "$config_path" 2>/dev/null; then
                    infra_ok "FS_METHOD set to 'direct'"
                else
                    infra_err "Failed to add FS_METHOD — please add manually:"
                    echo "        define('FS_METHOD', 'direct');"
                fi
            else
                infra_ok "FS_METHOD already defined in wp-config.php"
            fi
            break
        fi
    done

    # ── 6. Ensure uploads directory exists ──
    if ! platform_docker exec "$CONTAINER" test -d "${wp_root}/wp-content/uploads" 2>/dev/null; then
        infra_info "Creating wp-content/uploads..."
        platform_docker exec -u root "$CONTAINER" mkdir -p "${wp_root}/wp-content/uploads"
        platform_docker exec -u root "$CONTAINER" chown www:www-data "${wp_root}/wp-content/uploads"
        platform_docker exec -u root "$CONTAINER" chmod 2775 "${wp_root}/wp-content/uploads"
        infra_ok "uploads directory created"
    fi

    infra_ok "Done: ${project_name}"
}

infra_banner "WordPress Permission Fixer"

# Collect projects to process
if [ -n "${1:-}" ]; then
    # Specific project
    PROJECT_PATH="${WEB_ROOT}/$1"
    if ! platform_docker exec "$CONTAINER" test -d "$PROJECT_PATH" 2>/dev/null; then
        infra_err "Project not found: $1"
        echo "  Available projects in ${WEB_ROOT}:"
        platform_docker exec "$CONTAINER" ls -1 "$WEB_ROOT" 2>/dev/null | tr -d '\r' | while read -r dir; do
            echo "    - $dir"
        done
        exit 1
    fi
    fix_project "$PROJECT_PATH"
else
    # All projects
    FOUND=0
    # tr -d '\r': docker exec on Windows hands back CRLF, and a trailing \r
    # inside the path makes every container-side test miss.
    for project in $(platform_docker exec "$CONTAINER" ls -1 "$WEB_ROOT" 2>/dev/null | tr -d '\r'); do
        fix_project "${WEB_ROOT}/${project}"
        FOUND=$((FOUND + 1))
    done

    if [ "$FOUND" -eq 0 ]; then
        infra_warn "No projects found in ${WEB_ROOT}"
        exit 0
    fi
fi

infra_banner "Permissions Fixed Successfully!" "$INFRA_GREEN"
echo "  Owner: www (uid 1000) — editable in your IDE/terminal"
echo "  Group: www-data (gid 82) — writable by PHP-FPM (inherited via setgid)"
echo "  New files: default ACLs keep them rw for both, regardless of umask"
echo ""
