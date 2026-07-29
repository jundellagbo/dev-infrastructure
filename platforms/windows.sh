#!/usr/bin/env bash

# Windows through MSYS2 or Cygwin. gitbash.sh sources this and overrides the few
# things Git for Windows does differently, so the work lives in windows_*
# functions with thin platform_* wrappers over them.
#
# The things that break scripts here, all of which this file exists to absorb:
#
#   - /etc/hosts under MSYS is a private file no resolver ever reads; the real
#     one is Windows' own, under %SystemRoot%
#   - there is no sudo and no root - elevation means an Administrator shell
#   - MSYS rewrites anything that looks like a Unix path before a native program
#     sees it, so "docker exec c ls /var/www" arrives as C:/Program Files/...
#   - ping is Windows' ping.exe, which counts with -n rather than -c
#   - there is no getent, no systemd, and no wildcard DNS to configure at all

platform_label() { printf 'MSYS2/Cygwin on Windows (%s)\n' "$(uname -m)"; }

platform_installs_system_wide() { return 1; }              # per-user install
platform_bin_dir() { printf '%s\n' "${1:-$HOME}/.local/bin"; }

platform_pkg_manager() {
    local mgr
    for mgr in pacman winget scoop choco; do
        command -v "$mgr" >/dev/null 2>&1 && { printf '%s\n' "$mgr"; return 0; }
    done
    printf '%s\n' none
}

# --------------------------------------------------------------------- paths

windows_win_root() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "${SYSTEMROOT:-${SystemRoot:-C:\\Windows}}" 2>/dev/null || printf '%s\n' /c/Windows
    else
        printf '%s\n' /c/Windows
    fi
}

platform_hosts_file() { printf '%s\n' "$(windows_win_root)/System32/drivers/etc/hosts"; }

platform_native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

platform_shell_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Docker Desktop translates the bind mount and presents its own ownership; there
# is no setfacl here and nothing for one to fix.
platform_uses_posix_acls() { return 1; }

# No sudo to run a sed under, and the file is protected - this one is done by
# hand or not at all.
platform_hosts_remove_hint() {
    printf 'remove the %s line from %s (editor started as Administrator)\n' \
        "$1" "$(platform_hosts_file)"
}

# ---------------------------------------------------------------- privileges

platform_sudo() {
    infra_is_root && { "$@"; return; }
    infra_err "this needs Administrator - re-open your shell as administrator and re-run:"
    infra_note "$*"
    return 1
}

platform_require_root() {
    infra_is_root && return 0
    infra_err "Run this from a shell started as Administrator"
    return 1
}

# ------------------------------------------------------------------ resolving

# ping.exe counts with -n and takes its timeout in milliseconds.
platform_ping_once() { ping -n 1 -w 1000 "$1" 2>/dev/null; }

# No getent here; the ping fallback in infra_resolves_loopback does the work.
platform_resolve_addrs() { return 1; }

# --------------------------------------------------------------------- docker

# Both variables are needed: MSYS_NO_PATHCONV is Git for Windows', and
# MSYS2_ARG_CONV_EXCL is MSYS2's. Without them every container-side absolute
# path is rewritten into a Windows one before docker sees it.
platform_docker() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
}

# ------------------------------------------------------------------------ DNS

# There is no per-suffix resolver on Windows - no /etc/resolver, no resolved,
# and the hosts file takes no wildcards. One entry per project is the whole
# mechanism, which is what project-create.sh already writes.
windows_setup_dns() {
    infra_err "Windows has no wildcard DNS resolver to configure"
    infra_note "project-create.sh adds one hosts entry per project instead - that is the"
    infra_note "supported route here. The file is $(platform_hosts_file)"
    return 1
}

platform_setup_dns() { windows_setup_dns "$@"; }

# ---------------------------------------------------------------------- ports

windows_free_ports() {
    infra_warn "Nothing here for this script to uninstall."
    infra_warn "  IIS, XAMPP, Laragon and WampServer are managed by Windows itself -"
    infra_warn "  stop them from Services (services.msc) or their own control panel."
    infra_warn "  IIS specifically: 'net stop W3SVC' from an Administrator prompt."
}

platform_free_ports() { windows_free_ports "$@"; }

# ------------------------------------------------------------------------- CA

windows_trust_ca() {
    local crt native
    crt="$1"
    native="$(platform_native_path "$crt")"
    echo "From an Administrator PowerShell:"
    echo "  Import-Certificate -FilePath \"${native}\" \\"
    echo "    -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo ""
    echo "Or from an Administrator shell here:"
    echo "  certutil -addstore -f Root \"${native}\""
    echo ""
    echo "Or double-click ca.crt in Explorer -> Install Certificate -> Local"
    echo "Machine -> Trusted Root Certification Authorities."
}

platform_trust_ca() { windows_trust_ca "$@"; }
