#!/usr/bin/env bash

# Defaults for every platform hook, plus the helpers that don't vary. Sourced by
# platform.sh before the file for the detected platform, which overrides what it
# needs and inherits the rest.
#
# A hook whose default is "say this doesn't work here" is deliberate: a platform
# that can do the thing overrides it, and one that can't gives the same clear
# answer instead of failing halfway through with a package-manager error.
#
# Safe under `set -u`, never exits, never writes on load.

# ---------------------------------------------------------------------- output

# Colour only for a terminal that asked for it. In a log file or a pipe the
# escapes are noise, and a Git Bash hosted by cmd.exe rather than mintty prints
# them literally.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    INFRA_RED='\033[0;31m'; INFRA_GREEN='\033[0;32m'
    INFRA_YELLOW='\033[1;33m'; INFRA_BLUE='\033[0;34m'; INFRA_NC='\033[0m'
else
    INFRA_RED=''; INFRA_GREEN=''; INFRA_YELLOW=''; INFRA_BLUE=''; INFRA_NC=''
fi

# The tick, cross and arrow are UTF-8. A Windows console on a legacy code page
# renders them as mojibake, so drop to ASCII unless the locale claims UTF-8.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*)
        INFRA_SYM_OK='✓'; INFRA_SYM_BAD='✗'; INFRA_SYM_ARROW='→'; INFRA_SYM_RULE='─' ;;
    *)
        INFRA_SYM_OK='[ok]'; INFRA_SYM_BAD='[x]'; INFRA_SYM_ARROW='->'; INFRA_SYM_RULE='-' ;;
esac

# printf, not `echo -e`: -e is a bashism that prints itself verbatim under any
# other shell, and %s never re-reads a backslash the caller didn't write.
infra_ok()   { printf '%b%s %s%b\n' "$INFRA_GREEN"  "$INFRA_SYM_OK"    "$1" "$INFRA_NC"; }
infra_err()  { printf '%b%s %s%b\n' "$INFRA_RED"    "$INFRA_SYM_BAD"   "$1" "$INFRA_NC" >&2; }
infra_info() { printf '%b%s %s%b\n' "$INFRA_BLUE"   "$INFRA_SYM_ARROW" "$1" "$INFRA_NC"; }
infra_warn() { printf '%b! %s%b\n'  "$INFRA_YELLOW" "$1" "$INFRA_NC"; }

# An indented continuation under any of the above.
infra_note() { printf '    %s\n' "$1"; }

# Built with a loop rather than `printf '%40s' '' | tr ' ' "$rule"`: tr works on
# bytes, so it replaces each space with one byte of the rule glyph's three-byte
# UTF-8 sequence and the whole line comes out as mojibake.
infra_banner() {
    local colour="${2:-$INFRA_BLUE}" line="" i=0
    while [ $i -lt 40 ]; do
        line="${line}${INFRA_SYM_RULE}"
        i=$((i + 1))
    done
    printf '\n%b%s\n  %s\n%s%b\n\n' "$colour" "$line" "$1" "$line" "$INFRA_NC"
}

# ------------------------------------------------------------------ privileges

infra_is_root() { [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; }

# Family tests, for the handful of callers that genuinely care which kind of
# system they are on rather than which hook to call. WSL is Linux and Git Bash
# is Windows, so a check written against one name would miss the other.
infra_is_linux()   { [ "$INFRA_OS" = linux ]   || [ "$INFRA_OS" = wsl ]; }
infra_is_macos()   { [ "$INFRA_OS" = macos ]; }
infra_is_windows() { [ "$INFRA_OS" = windows ] || [ "$INFRA_OS" = gitbash ]; }

infra_require_command() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            infra_err "Missing required command: $cmd"
            return 1
        fi
    done
}

# Refuse to continue where a script's whole job is impossible. The hint is what
# to do instead, so the message is an answer rather than a "no".
infra_unsupported() {
    infra_err "$(basename "${0:-this script}") does not run on $(platform_label)"
    [ -n "${1:-}" ] && infra_note "$1"
    return 1
}

# ---------------------------------------------------------------------- hooks
#
# Everything below is overridable. A platform file redefines what differs.

platform_label() { uname -s 2>/dev/null || echo unknown; }

# Does this platform install tools system-wide under sudo, or per-user into a
# home directory? Only about installs - a privileged operation elsewhere asks
# for root itself, so a platform that can't do the operation at all gets to say
# so instead of demanding a sudo first.
platform_installs_system_wide() { return 0; }

# Where binaries this repo installs land. Takes the target home directory,
# because under sudo $HOME is root's and the tools belong to the human who
# typed it; defaults to this shell's own when the caller has no opinion.
platform_bin_dir() { printf '%s\n' /usr/local/bin; }

# Run a command as root, however this platform gets there.
platform_sudo() {
    if infra_is_root; then
        "$@"
        return
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return
    fi
    infra_err "this needs root and sudo is not installed - run it as root:"
    infra_note "$*"
    return 1
}

platform_require_root() {
    infra_is_root && return 0
    infra_err "Run this script with sudo:"
    infra_note "sudo ${0:-./script.sh}"
    return 1
}

# Where a "127.0.0.1 <name>" line has to go for the browser to see it.
platform_hosts_file() { printf '%s\n' /etc/hosts; }

# A second hosts file on a Windows side, where one exists - only WSL has both.
platform_windows_hosts_file() { return 1; }

# How to take a project's line back out of the hosts file. GNU sed by default;
# BSD sed wants an explicit backup suffix after -i and would otherwise eat the
# pattern as one, and the Windows shells have no sudo to run it under.
platform_hosts_remove_hint() {
    printf 'sudo sed -i "/%s/d" %s\n' "$1" "$(platform_hosts_file)"
}

# True where the shell itself ships with git, so nothing offers to install it.
platform_has_bundled_git() { return 1; }

# A path in the notation something outside this shell expects. Only the Windows
# platforms translate; everywhere else the path is already native.
platform_native_path() { printf '%s\n' "$1"; }

# The inverse: a path another program reported, in a form this shell can open.
# docker inspect answers in the host's notation, which on Windows is C:\...
platform_shell_path() { printf '%s\n' "$1"; }

# Does the host filesystem carry POSIX ACLs, so setfacl means something? Docker
# Desktop's file sharing on macOS and Windows presents its own ownership and
# there is no setfacl to honour one anyway.
platform_uses_posix_acls() { return 0; }

# docker, with whatever this platform needs around it.
platform_docker() { docker "$@"; }

# Addresses <name> resolves to, one per line, through the system resolver.
# getent is glibc's; the platforms without it override this.
platform_resolve_addrs() {
    command -v getent >/dev/null 2>&1 || return 1
    getent hosts "$1" 2>/dev/null | awk '{print $1}'
}

# ping's count flag: -c everywhere except Windows' own ping.exe.
platform_ping_once() { ping -c 1 -W 1 "$1" 2>/dev/null; }

# The rc files a new shell of this user actually reads. Same reason as
# platform_bin_dir for taking the home and shell rather than reading $HOME:
# under sudo they are root's, and this configures the invoking user's shell.
platform_rc_files() {
    local home="${1:-$HOME}" shell_name="${2:-$(basename "${SHELL:-bash}")}"
    case "$shell_name" in
        zsh) printf '%s\n' "${home}/.zshrc" ;;
        *)   printf '%s\n' "${home}/.bashrc" ;;
    esac
}

# Persistent wildcard DNS for *.<domain> pointing at 127.0.0.1.
platform_setup_dns() {
    infra_unsupported "no wildcard resolver here - add one hosts entry per project to $(platform_hosts_file)"
}

# Take down host web/database services so the Docker stack can have the ports.
platform_free_ports() {
    infra_unsupported "stop your host web and database services by hand"
}

# How to trust the generated CA. Printed, not run: adding a root certificate is
# a decision the user makes with their eyes open, on every platform.
platform_trust_ca() {
    printf 'Add %s to this system'\''s trust store.\n' "$1"
}

# The package manager, if this platform has one this repo knows how to drive.
platform_pkg_manager() { printf '%s\n' none; }

# ----------------------------------------------------------- generic helpers
#
# Built on the hooks above, so they work anywhere without knowing where.

# Does <name> resolve to 127.0.0.1? Falls back to ping, which exists everywhere
# and - unlike dig or nslookup - consults the hosts file the way a browser does.
infra_resolves_loopback() {
    local name="$1" addrs=""

    addrs="$(platform_resolve_addrs "$name" 2>/dev/null)" || addrs=""

    if [ -z "$addrs" ]; then
        # Only the first line matters and the address is printed before any
        # reply is waited for, so a lost packet doesn't change the answer.
        # Windows brackets the address, everyone else parenthesises it.
        addrs="$(platform_ping_once "$name" | sed -n '1s/.*[[(]\([0-9.]*\)[])].*/\1/p')"
    fi

    printf '%s\n' "$addrs" | grep -qx '127\.0\.0\.1'
}

# The dnsmasq invocation behind every platform's wildcard DNS. --no-resolv and
# --no-hosts stop it becoming a general-purpose resolver: it answers for this
# one suffix, and --bind-interfaces keeps it off every address but loopback.
infra_dnsmasq_args() {
    printf '%s\n' \
        --keep-in-foreground --no-resolv --no-hosts \
        --listen-address=127.0.0.1 --bind-interfaces \
        "--address=/${1}/127.0.0.1" \
        "--address=/.${1}/127.0.0.1"
}

# What is listening on the stack's ports, in whatever tool this box has. This is
# the answer to "docker compose up says port 80 is in use" on every platform.
infra_report_ports() {
    local port hit found=0
    for port in "$@"; do
        hit=""
        if command -v ss >/dev/null 2>&1; then
            hit="$(ss -lntp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p')"
        elif command -v lsof >/dev/null 2>&1; then
            hit="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2)"
        elif command -v netstat >/dev/null 2>&1; then
            hit="$(netstat -an 2>/dev/null | grep -i listen | grep -E "[:.]${port}[[:space:]]")"
        fi
        if [ -n "$hit" ]; then
            infra_warn "port ${port} is still in use:"
            printf '%s\n' "$hit" | sed 's/^/      /'
            found=1
        fi
    done
    [ "$found" -eq 0 ] && infra_ok "All required ports are free"
    return 0
}

infra_docker_running() {
    platform_docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null | grep -q true
}

# Firefox ships its own trust store on every platform, so this footnote belongs
# to all of them.
infra_firefox_note() {
    infra_warn "Firefox keeps its own certificate store: Settings -> Privacy & Security"
    infra_warn "  -> Certificates -> View Certificates -> Authorities -> Import."
    infra_warn "Restart the browser afterwards - trust decisions are cached."
}
