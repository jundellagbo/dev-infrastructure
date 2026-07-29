#!/usr/bin/env bash

# macOS: launchd instead of systemd, Homebrew instead of apt, /etc/resolver
# instead of resolved, and zsh as the login shell since Catalina.
#
# Installs are per-user here. Homebrew refuses to run as root, /usr/local is not
# the shared territory it is on Linux, and a Mac has one human on it - so the
# bin directory is ~/.local/bin and sudo only appears for the two things that
# genuinely need it, the DNS daemon and the system keychain.

platform_label() {
    local ver
    ver="$(sw_vers -productVersion 2>/dev/null)"
    printf 'macOS%s (%s)\n' "${ver:+ $ver}" "$(uname -m)"
}

platform_installs_system_wide() { return 1; }              # per-user install
platform_bin_dir() { printf '%s\n' "${1:-$HOME}/.local/bin"; }

platform_pkg_manager() {
    command -v brew >/dev/null 2>&1 && printf '%s\n' brew || printf '%s\n' none
}

# There is no getent on macOS; dscacheutil is the equivalent question.
platform_resolve_addrs() {
    command -v dscacheutil >/dev/null 2>&1 || return 1
    dscacheutil -q host -a name "$1" 2>/dev/null | awk '/^ip_address:/ {print $2}'
}

# BSD ping's -W is milliseconds rather than seconds, but only the first line is
# read and the address is printed before any reply is waited for.
platform_ping_once() { ping -c 1 -W 1 "$1" 2>/dev/null; }

# Docker Desktop's virtiofs/gRPC-FUSE sharing presents files to the host as the
# host user whatever the container did, and macOS ACLs are a different model
# from POSIX ones - setfacl doesn't exist and wouldn't be the fix.
platform_uses_posix_acls() { return 1; }

# BSD sed reads the word after -i as the backup suffix, so it needs the empty
# one spelled out or it would treat the pattern as a filename extension.
platform_hosts_remove_hint() {
    printf "sudo sed -i '' '/%s/d' %s\n" "$1" "$(platform_hosts_file)"
}

# Terminal.app opens a *login* shell for every window, which reads .bash_profile
# and never .bashrc - so a line written only to .bashrc silently does nothing.
platform_rc_files() {
    local home="${1:-$HOME}" shell_name="${2:-$(basename "${SHELL:-zsh}")}"
    case "$shell_name" in
        zsh) printf '%s\n' "${home}/.zshrc" ;;
        *)   printf '%s\n' "${home}/.bashrc" "${home}/.bash_profile" ;;
    esac
}

# ------------------------------------------------------------------------ DNS

# macOS has no wildcard in /etc/hosts, but its resolver reads
# /etc/resolver/<domain> for per-suffix nameservers - that file is what makes a
# wildcard possible. It just needs something answering on 127.0.0.1, and the
# daemon here is ours rather than Homebrew's dnsmasq service so this script owns
# what it installed, the same way the systemd path does on Linux.
macos_setup_dns() {
    local domain="$1" label="local.infra.dev-local-dns" plist arg args_xml="" dnsmasq_bin
    plist="/Library/LaunchDaemons/${label}.plist"

    # A system LaunchDaemon and /etc/resolver both need root, even though every
    # other thing this repo installs on a Mac is per-user.
    platform_require_root || return 1

    if ! dnsmasq_bin="$(command -v dnsmasq)"; then
        infra_err "dnsmasq is not installed"
        infra_note "brew install dnsmasq"
        return 1
    fi

    while IFS= read -r arg; do
        args_xml="${args_xml}		<string>${arg}</string>
"
    done <<EOF
$(infra_dnsmasq_args "$domain")
EOF

    infra_info "Installing ${plist}..."
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${dnsmasq_bin}</string>
${args_xml}	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
    chown root:wheel "$plist"
    chmod 644 "$plist"

    # bootout/bootstrap is the current API; load -w is what works on 10.10 and
    # older. Either way it restarts, so an edited plist takes effect.
    launchctl bootout "system/${label}" 2>/dev/null || true
    if ! launchctl bootstrap system "$plist" 2>/dev/null; then
        launchctl unload -w "$plist" 2>/dev/null || true
        launchctl load -w "$plist"
    fi
    infra_ok "${label} started"

    infra_info "Pointing the system resolver at it for *.${domain}..."
    mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\n' > "/etc/resolver/${domain}"
    chmod 644 "/etc/resolver/${domain}"
    # The resolver caches negative answers from before this existed, so the
    # flush is the difference between working now and working after lunch.
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    infra_ok "/etc/resolver/${domain} written"
}

platform_setup_dns() { macos_setup_dns "$@"; }

# ---------------------------------------------------------------------- ports

# Stopping is the whole job here. Uninstalling is not: brew refuses to run as
# root and this runs under sudo, and pulling formulae out from under someone's
# other projects is not a thing to do unasked - so the commands get printed.
macos_free_ports() {
    local brew_user="${SUDO_USER:-}"

    # launchctl against the system domain and apachectl both need it, even
    # though everything this repo *installs* on a Mac is per-user.
    platform_require_root || return 1

    if [ -n "$brew_user" ] && su - "$brew_user" -c 'command -v brew >/dev/null 2>&1'; then
        infra_info "Stopping Homebrew services for ${brew_user}..."
        su - "$brew_user" -c \
            'brew services stop httpd nginx mysql mariadb postgresql 2>/dev/null' || true
        infra_ok "Homebrew services stopped"
        infra_warn "Uninstall them yourself if you want them gone (not as root):"
        infra_warn "  brew uninstall httpd nginx mysql postgresql"
    else
        infra_warn "Homebrew not found for the invoking user - skipping its services"
    fi

    # macOS ships Apache. It is off by default, but one past "sudo apachectl
    # start" survives every reboot through this plist.
    infra_info "Stopping the built-in Apache..."
    apachectl stop 2>/dev/null || true
    launchctl bootout system/org.apache.httpd 2>/dev/null \
        || launchctl unload -w /System/Library/LaunchDaemons/org.apache.httpd.plist 2>/dev/null \
        || true
    infra_ok "Built-in Apache stopped"
    infra_warn "Database data directories are left untouched"
}

platform_free_ports() { macos_free_ports "$@"; }

# ------------------------------------------------------------------------- CA

platform_trust_ca() {
    local crt="$1"
    echo "System keychain (Safari, Chrome, curl):"
    echo "  sudo security add-trusted-cert -d -r trustRoot \\"
    echo "    -k /Library/Keychains/System.keychain \"${crt}\""
    echo ""
    echo "Or open Keychain Access, drag ca.crt into System, then set it to"
    echo "\"Always Trust\" in its Get Info panel."
}
