#!/usr/bin/env bash

# WSL: Linux, plus a Windows host that resolves names and browses the web on its
# own. Everything apt, systemd and /etc/hosts still applies - so this inherits
# the Linux behaviour and adds the half that lives on the other side of the
# boundary, which is where WSL setups actually go wrong:
#
#   - the browser is a Windows program and never reads /etc/hosts
#   - WSL rewrites /etc/hosts and /etc/resolv.conf on every boot unless
#     /etc/wsl.conf turns that off, quietly undoing what was configured
#   - systemd is opt-in, so a systemd unit may have nothing to run it
#   - certificates have to be trusted twice, once on each side

. "${INFRA_PLATFORM_DIR}/linux.sh"

platform_label() { printf 'WSL (%s)\n' "${WSL_DISTRO_NAME:-Linux}"; }

# The Windows side, as paths this shell can open.
wsl_win_root() { printf '%s\n' /mnt/c/Windows; }
platform_windows_hosts_file() { printf '%s\n' "$(wsl_win_root)/System32/drivers/etc/hosts"; }

platform_native_path() {
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Said after anything that writes a hosts entry or configures a resolver: inside
# the distro it worked, and the browser still won't see it.
wsl_browser_note() {
    infra_warn "WSL: this covers lookups made inside the distro (curl, wp-cli, PHP)."
    infra_warn "  Your Windows browser resolves on its own, so add the same entry to"
    infra_note "$(platform_windows_hosts_file)"
    infra_warn "  (open it in Notepad started as Administrator), and set"
    infra_warn "  generateHosts=false / generateResolvConf=false under [network] in"
    infra_warn "  /etc/wsl.conf so WSL stops overwriting what you configured."
}

platform_setup_dns() {
    linux_setup_dns "$@" || return 1
    echo ""
    wsl_browser_note
}

platform_trust_ca() {
    local crt="$1"
    echo "Two trust stores, because two systems are involved."
    echo ""
    echo "1. Inside WSL (curl, composer, wp-cli):"
    echo "     sudo cp \"${crt}\" /usr/local/share/ca-certificates/dev-local-ca.crt"
    echo "     sudo update-ca-certificates"
    echo ""
    echo "2. On Windows, where your browser actually checks:"
    echo "     Import-Certificate -FilePath \"$(platform_native_path "$crt")\" \\"
    echo "       -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo "   from an Administrator PowerShell - or double-click ca.crt in Explorer"
    echo "   -> Install Certificate -> Local Machine -> Trusted Root Certification"
    echo "   Authorities."
}
