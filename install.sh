#!/usr/bin/env bash

# Install PHP (multiple versions + switcher), Composer, WP-CLI, Node, git, the
# GitHub CLI and the starship prompt on the host.
#
#   sudo ./install.sh                          # everything: PHP 8.3, default 8.3
#   sudo ./install.sh --versions 8.2 8.3 8.4   # only these (also: --versions=8.2,8.3)
#   sudo ./install.sh --default 8.2            # pick the default CLI version
#   sudo ./install.sh --no-composer --no-wp    # skip the extras
#   sudo ./install.sh --no-node                # skip Node/nvm
#   sudo ./install.sh --node-version 20        # install this Node major (default: --lts)
#   sudo ./install.sh --no-git --no-gh         # skip git and the GitHub CLI
#   sudo ./install.sh --no-starship            # skip the starship prompt
#
# git and gh are only installed when they are missing - a run never upgrades or
# reconfigures the ones already on the box unless their selector asks for it.
#
# Component selectors: --php --composer --wp --node --git --gh --starship
#
# On their own they install ONLY what they name, and reinstall it if it is
# already there. After --uninstall they remove only what they name.
#
#   sudo ./install.sh --node                   # (re)install just Node via nvm
#   sudo ./install.sh --gh                     # (re)install just the GitHub CLI
#   sudo ./install.sh --starship               # (re)install the prompt and its config
#   sudo ./install.sh --php 8.2 8.3            # only these PHP versions
#   sudo ./install.sh --uninstall --php 8.1 8.2 # uninstall selected PHP versions
#   sudo ./install.sh --uninstall               # uninstall everything managed here
#
# Afterwards "phpsw" switches the active CLI/FPM version and "nvm" switches Node:
#
#   phpsw          # list installed PHP versions
#   phpsw 8.2      # make 8.2 the default
#   nvm ls         # list installed Node versions
#   nvm use 20     # switch the active Node version
#
# Platforms
#
#   Debian/Ubuntu (incl. WSL)  everything, system-wide in /usr/local/bin. Run it
#                              with sudo; PHP comes from ppa:ondrej/php, which is
#                              what makes several versions side by side possible.
#   macOS                      Composer, WP-CLI, Node, git, gh and starship, all
#                              per-user in ~/.local/bin. Run it WITHOUT sudo -
#                              Homebrew refuses to work as root. PHP is Homebrew's
#                              to install (brew install php@8.3); there is no
#                              phpsw, `brew link` is the switcher.
#   Git Bash on Windows        Composer, WP-CLI, gh and starship, per-user. Node
#                              needs nvm-windows, which is an .exe installer.
#   other Linux                everything except PHP; no other distro ships the
#                              side-by-side versions this expects.
#
# The Claude Code CLI, its MCP servers and its plugins are installed separately:
# see install.sh in the llm-infrastructure repo.

set -e

# ------------------------------------------------------------------- platform

# This file is the bootstrap, but it is never alone: it lives in the checkout
# next to platforms/, so it uses the same platform layer every other script here
# does rather than repeating the detection.
INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -r "${INFRA_DIR}/platforms/platform.sh" ]; then
    echo "install.sh needs the platforms/ directory next to it - run it from the checkout" >&2
    exit 1
fi
. "${INFRA_DIR}/platforms/platform.sh"

# PHP here means several versions side by side with a switcher, and that rests
# on ppa:ondrej/php - no other packaging offers it, so PHP is an apt-only
# component while everything else installs from upstream on any platform.
HAS_APT=0
command -v apt-get >/dev/null 2>&1 && HAS_APT=1

# Linux is a shared box and installs system-wide under sudo, as it always has.
# macOS and the Windows shells are single-user: Homebrew refuses to run as root,
# an MSYS "Administrator" shell is a different animal, and neither has a
# /usr/local/bin worth fighting for - so there the install is per-user and sudo
# never appears.
if platform_installs_system_wide; then
    NEEDS_ROOT=1
else
    NEEDS_ROOT=0
fi

PHP_VERSIONS="8.3"
DEFAULT_VERSION="8.3"
INSTALL_PHP=1
INSTALL_COMPOSER=1
INSTALL_WPCLI=1
INSTALL_NODE=1
NODE_VERSION="--lts"
INSTALL_GIT=1
INSTALL_GH=1
INSTALL_STARSHIP=1
UNINSTALL_PHP=0
UNINSTALL_COMPOSER=0
UNINSTALL_WPCLI=0
UNINSTALL_NODE=0
UNINSTALL_GIT=0
UNINSTALL_GH=0
UNINSTALL_STARSHIP=0
UNINSTALL_ALL=0

# Component selectors (--php, --node, ...) mean "only these": which side they
# apply to depends on whether --uninstall came along.
SEL_PHP=0
SEL_COMPOSER=0
SEL_WPCLI=0
SEL_NODE=0
SEL_GIT=0
SEL_GH=0
SEL_STARSHIP=0
selector=0
# Picking a component explicitly means "(re)do this one", so the install steps
# that normally skip an already-present tool run anyway.
FORCE_REINSTALL=0

# --versions takes one or more versions: "--versions 8.2 8.3", --versions=8.2,8.3
# and --versions "8.2 8.3" all mean the same thing.
picked_versions=""
add_versions() {
    local v
    for v in $(printf '%s' "$1" | tr ',' ' '); do
        picked_versions="$picked_versions $v"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --versions|-V)      add_versions "$2"; shift ;;
        --versions=*)       add_versions "${1#*=}" ;;
        --uninstall)        UNINSTALL_MODE=1 ;;
        --php)              SEL_PHP=1; selector=1 ;;
        --composer)         SEL_COMPOSER=1; selector=1 ;;
        --wp|--wpcli)       SEL_WPCLI=1; selector=1 ;;
        --node)             SEL_NODE=1; selector=1 ;;
        --git)              SEL_GIT=1; selector=1 ;;
        --gh|--github-cli)  SEL_GH=1; selector=1 ;;
        --starship)         SEL_STARSHIP=1; selector=1 ;;
        --default|-d)       DEFAULT_VERSION="$2"; shift ;;
        --default=*)        DEFAULT_VERSION="${1#*=}" ;;
        --no-composer)      INSTALL_COMPOSER=0 ;;
        --no-wp|--no-wpcli) INSTALL_WPCLI=0 ;;
        --no-node)          INSTALL_NODE=0 ;;
        --no-git)           INSTALL_GIT=0 ;;
        --no-gh)            INSTALL_GH=0 ;;
        --no-starship)      INSTALL_STARSHIP=0 ;;
        --node-version)     NODE_VERSION="$2"; shift ;;
        --node-version=*)   NODE_VERSION="${1#*=}" ;;
        -h|--help)
            # The header comment is the help text: everything from line 3 up to
            # the first non-comment line, so it can't drift out of range.
            awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        # Bare version numbers extend the list: "--versions 8.2 8.3 8.4"
        [0-9].[0-9]|[0-9].[0-9][0-9]) add_versions "$1" ;;
        *) infra_err "unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ -n "$picked_versions" ]; then
    PHP_VERSIONS="${picked_versions# }"
fi

UNINSTALL_MODE="${UNINSTALL_MODE:-0}"

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$selector" -eq 0 ]; then
        # Bare --uninstall means everything this script manages
        UNINSTALL_ALL=1
        SEL_PHP=1; SEL_COMPOSER=1; SEL_WPCLI=1; SEL_NODE=1; SEL_GH=1; SEL_STARSHIP=1
        # Not SEL_GIT: git is a base tool the rest of this repo runs on, so a
        # bare --uninstall never takes it away. "--uninstall --git" still says so.
    fi
    UNINSTALL_PHP=$SEL_PHP
    UNINSTALL_COMPOSER=$SEL_COMPOSER
    UNINSTALL_WPCLI=$SEL_WPCLI
    UNINSTALL_NODE=$SEL_NODE
    UNINSTALL_GIT=$SEL_GIT
    UNINSTALL_GH=$SEL_GH
    UNINSTALL_STARSHIP=$SEL_STARSHIP
elif [ "$selector" -eq 1 ]; then
    # Install mode with selectors: only the named components, and they are
    # (re)installed rather than skipped as already-present. --no-* is redundant
    # here - anything not selected is off already.
    INSTALL_PHP=$SEL_PHP
    INSTALL_COMPOSER=$SEL_COMPOSER
    INSTALL_WPCLI=$SEL_WPCLI
    INSTALL_NODE=$SEL_NODE
    INSTALL_GIT=$SEL_GIT
    INSTALL_GH=$SEL_GH
    INSTALL_STARSHIP=$SEL_STARSHIP
    FORCE_REINSTALL=1
fi

if [ -n "$picked_versions" ] && [ "$selector" -eq 1 ] && [ "$SEL_PHP" -eq 0 ]; then
    infra_err "PHP versions require the --php selector"
    exit 1
fi

for version in $PHP_VERSIONS; do
    case "$version" in
        [0-9].[0-9]|[0-9].[0-9][0-9]) ;;
        *) infra_err "invalid PHP version: $version"; exit 1 ;;
    esac
done

# ----------------------------------------------------------- platform gating

# Turn off what this platform genuinely cannot do, and say why once rather than
# failing halfway through with a package-manager error. A component the user
# asked for by name is worth a warning; one that was only on by default isn't.
skip_component() {
    local name="$1" reason="$2" selected="$3"
    if [ "$selected" -eq 1 ]; then
        infra_warn "skipping ${name}: ${reason}"
    fi
    return 0
}

if [ $HAS_APT -eq 0 ] && [ $INSTALL_PHP -eq 1 ]; then
    if [ "$UNINSTALL_MODE" -eq 1 ]; then
        skip_component PHP "nothing here installs PHP through apt, so there is none to remove" "$SEL_PHP"
    else
        case "$INFRA_OS" in
            macos)   skip_component PHP "install it with Homebrew - brew install php@8.3" "$SEL_PHP" ;;
            windows|gitbash)
                     skip_component PHP "no PHP packaging for a Windows shell - use the Docker stack, or php.net's Windows build" "$SEL_PHP" ;;
            *)       skip_component PHP "side-by-side versions need ppa:ondrej/php, which is Debian/Ubuntu only" "$SEL_PHP" ;;
        esac
    fi
    INSTALL_PHP=0
    UNINSTALL_PHP=0
fi

# nvm is a POSIX shell script and has no Windows support at all - nvm-windows is
# a separate project with its own .exe installer.
if infra_is_windows && [ $INSTALL_NODE -eq 1 ]; then
    skip_component Node "nvm has no Windows build - see github.com/coreybutler/nvm-windows" "$SEL_NODE"
    INSTALL_NODE=0
    UNINSTALL_NODE=0
fi

if infra_is_windows && [ $INSTALL_GIT -eq 1 ]; then
    # A Git Bash prompt exists because git for Windows is already installed.
    INSTALL_GIT=0
fi

if [ "$UNINSTALL_MODE" -eq 0 ] && [ $INSTALL_PHP -eq 0 ] && [ $INSTALL_COMPOSER -eq 0 ] \
   && [ $INSTALL_WPCLI -eq 0 ] && [ $INSTALL_NODE -eq 0 ] && [ $INSTALL_GIT -eq 0 ] \
   && [ $INSTALL_GH -eq 0 ] && [ $INSTALL_STARSHIP -eq 0 ]; then
    infra_err "nothing left to install on $(platform_label)"
    exit 1
fi

# --------------------------------------------------------------- privileges

if [ "$NEEDS_ROOT" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        infra_err "This script must be run with sudo on $(platform_label)"
        printf '    sudo %s\n' "$0" >&2
        exit 1
    fi
    if [ $HAS_APT -eq 0 ] && { [ $INSTALL_GIT -eq 1 ] || [ $INSTALL_GH -eq 1 ]; }; then
        infra_warn "no apt-get here - git and gh have to come from this distro's package manager"
        INSTALL_GIT=0
        INSTALL_GH=0
    fi
elif [ "$(id -u)" -eq 0 ]; then
    infra_err "Do not run this with sudo on $(platform_label) - it installs per-user"
    printf '    %s\n' "$0" >&2
    exit 1
fi

# The user whose home directory and shell this configures. Under sudo that is
# the human who typed it, not root.
TOOL_USER="${SUDO_USER:-$(id -un)}"

# getent is glibc's; macOS answers through dscl and neither exists on MSYS, so
# fall through to tilde expansion, which every shell does.
home_of() {
    local user="$1" home=""
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [ -n "$home" ] || home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -n "$home" ] || home="$(eval printf '%s' "~${user}" 2>/dev/null)"
    case "$home" in ''|'~'*) return 1 ;; esac
    printf '%s\n' "$home"
}
TOOL_HOME="$(home_of "$TOOL_USER" || printf '%s' "$HOME")"

login_shell_of() {
    local user="$1" shell=""
    shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7)"
    [ -n "$shell" ] || shell="$(dscl . -read "/Users/${user}" UserShell 2>/dev/null | awk '{print $2}')"
    [ -n "$shell" ] || shell="${SHELL:-/bin/bash}"
    printf '%s\n' "$shell"
}
TOOL_SHELL="$(basename "$(login_shell_of "$TOOL_USER")")"

# Run something as the target user with their profile loaded. Under sudo that
# means dropping privileges; when already running as them it just means a login
# shell, so nvm and friends see the same environment either way.
run_as_user() {
    if [ "$NEEDS_ROOT" -eq 1 ] && [ "$(id -un)" != "$TOOL_USER" ]; then
        su - "$TOOL_USER" -c "$1"
    else
        bash -lc "$1"
    fi
}

# Where binaries land: /usr/local/bin where the install is system-wide, the
# per-user ~/.local/bin otherwise. The target home is passed in because under
# sudo $HOME is root's and these tools belong to the human who typed it.
BIN_DIR="$(platform_bin_dir "$TOOL_HOME")"
mkdir -p "$BIN_DIR"

# --------------------------------------------------------------- uninstall PHP

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$UNINSTALL_PHP" -eq 1 ]; then
        if [ -z "$picked_versions" ]; then
            PHP_VERSIONS="$(dpkg-query -W -f='${Package}\n' 'php[0-9].[0-9]-cli' 2>/dev/null \
                | sed -n 's/^php\([0-9][0-9]*\.[0-9][0-9]*\)-cli$/\1/p' | sort -Vu)"
        fi

        if [ -z "$PHP_VERSIONS" ]; then
            infra_warn "No PHP versions are installed"
        fi

    for version in $PHP_VERSIONS; do
        infra_info "Uninstalling PHP ${version}..."
        pkgs="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk -v prefix="php${version}" '
            $0 == prefix || index($0, prefix "-") == 1
        ')"

        if [ -z "$pkgs" ]; then
            infra_warn "PHP ${version} is not installed - skipping"
            continue
        fi

        # shellcheck disable=SC2086
        apt-get purge -y -qq $pkgs >/dev/null
        infra_ok "PHP ${version} uninstalled"
    done

    remaining="$(ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V)"
    if [ -n "$remaining" ]; then
        fallback="$(printf '%s\n' "$remaining" | tail -1)"
        if [ -x "${BIN_DIR}/phpsw" ]; then
            infra_info "Switching the default to remaining PHP ${fallback}..."
            "${BIN_DIR}/phpsw" "$fallback"
        fi
        infra_info "Remaining PHP versions: $(printf '%s\n' "$remaining" | tr '\n' ' ')"
    else
        infra_warn "No PHP versions remain installed"
    fi
    fi

    if [ "$UNINSTALL_COMPOSER" -eq 1 ]; then
        infra_info "Uninstalling Composer..."
        rm -f "${BIN_DIR}/composer"
        if [ "$NEEDS_ROOT" -eq 1 ]; then
            rm -f /etc/profile.d/composer.sh
        fi
        infra_ok "Composer uninstalled"
    fi

    if [ "$UNINSTALL_WPCLI" -eq 1 ]; then
        infra_info "Uninstalling WP-CLI..."
        rm -f "${BIN_DIR}/wp" "${BIN_DIR}/wp-cli.phar"
        infra_ok "WP-CLI uninstalled"
    fi

    if [ "$UNINSTALL_NODE" -eq 1 ]; then
        infra_info "Uninstalling Node and nvm for ${TOOL_USER}..."
        rm -rf "${TOOL_HOME}/.nvm"
        infra_ok "Node and nvm uninstalled"
    fi

    if [ "$UNINSTALL_GH" -eq 1 ]; then
        if [ $HAS_APT -eq 1 ] && { command -v gh >/dev/null 2>&1 || [ -f /etc/apt/sources.list.d/github-cli.list ]; }; then
            infra_info "Uninstalling the GitHub CLI..."
            apt-get purge -y -qq gh >/dev/null 2>&1 || true
            # The repo and its key are ours, so they go with the package - left
            # behind they keep showing up in every future apt update.
            rm -f /etc/apt/sources.list.d/github-cli.list \
                  /etc/apt/keyrings/githubcli-archive-keyring.gpg
            apt-get update -qq >/dev/null 2>&1 || true
            infra_ok "gh uninstalled"
        elif command -v gh >/dev/null 2>&1; then
            # Installed by something this script doesn't own (brew, winget,
            # scoop) - removing it is that tool's job, not ours.
            infra_warn "gh came from another package manager - remove it there:"
            case "$INFRA_OS" in
                macos)           printf '    brew uninstall gh\n' ;;
                windows|gitbash) printf '    winget uninstall GitHub.cli\n' ;;
                *)               printf '    (your distro package manager)\n' ;;
            esac
        else
            infra_warn "gh is not installed - skipping"
        fi
    fi

    if [ "$UNINSTALL_GIT" -eq 1 ]; then
        # Asked for explicitly (a bare --uninstall never selects git), and still
        # declined: git.sh, the worktree helpers and this repo's whole agent
        # workflow run on git, and apt would take every package depending on it
        # along too. Removing it is a decision for a human at a prompt.
        infra_warn "not uninstalling git - git.sh, the worktree helpers and the"
        infra_warn "  agent workflow all need it, and its package manager would pull"
        infra_warn "  its dependents out with it. Remove it by hand if you mean to."
    fi

    if [ "$UNINSTALL_STARSHIP" -eq 1 ]; then
        infra_info "Uninstalling starship..."
        rm -f "${BIN_DIR}/starship"
        # Only the config this script wrote - one the user edited or brought
        # themselves loses the marker line and is theirs to keep.
        starship_toml="${TOOL_HOME}/.config/starship.toml"
        if [ -f "$starship_toml" ] && grep -q '^# managed by infra install.sh' "$starship_toml"; then
            rm -f "$starship_toml"
            infra_info "removed the generated ${starship_toml}"
        fi
        # The machine-wide init drop-in is always ours - drop it too. It only
        # ever exists where there is an /etc/profile.d to drop it into.
        if [ "$NEEDS_ROOT" -eq 1 ]; then
            rm -f /etc/profile.d/starship.sh
        fi
        # And the statusLine script + its settings entry, when the entry is ours.
        rm -f "${TOOL_HOME}/.config/starship-statusline.sh"
        claude_settings="${TOOL_HOME}/.claude/settings.json"
        if [ -f "$claude_settings" ] && command -v jq >/dev/null 2>&1; then
            cur_sl="$(jq -r '.statusLine.command // ""' "$claude_settings" 2>/dev/null)"
            case "$cur_sl" in
                *starship-statusline*)
                    tmp="$(mktemp)"
                    if jq 'del(.statusLine)' "$claude_settings" > "$tmp" 2>/dev/null; then
                        mv "$tmp" "$claude_settings"
                        chown "$TOOL_USER" "$claude_settings" 2>/dev/null || true
                        infra_info "removed the starship statusLine from ${claude_settings}"
                    else
                        rm -f "$tmp"
                    fi ;;
            esac
        fi
        infra_ok "starship uninstalled - git.sh falls back to its own prompt"
    fi

    if [ "$UNINSTALL_ALL" -eq 1 ]; then
        rm -f "${BIN_DIR}/phpsw"
        infra_ok "phpsw uninstalled"
    fi

    infra_ok "Uninstall complete"
    exit 0
fi

case " $PHP_VERSIONS " in
    *" $DEFAULT_VERSION "*) ;;
    *)  # Fall back to the newest version actually being installed
        for v in $PHP_VERSIONS; do DEFAULT_VERSION="$v"; done ;;
esac

export DEBIAN_FRONTEND=noninteractive

if [ $INSTALL_PHP -eq 1 ]; then
    infra_info "PHP versions: ${PHP_VERSIONS} (default ${DEFAULT_VERSION})"
fi

# Extensions every Laravel app needs, plus the WordPress/dev extras.
# Laravel requires ctype, curl, dom, fileinfo, filter, hash, mbstring, openssl,
# pcre, pdo, session and tokenizer - those ship inside -cli/-common/-xml.
PHP_EXTENSIONS="
bcmath
bz2
cli
common
curl
dev
fpm
gd
gmp
igbinary
imagick
imap
intl
ldap
mbstring
memcached
msgpack
mysql
opcache
pgsql
readline
redis
soap
sqlite3
tidy
xdebug
xml
xsl
zip
"

# ---------------------------------------------------------------- repositories

# git and gh install only when they are missing, so settle that before the
# prerequisite block: a box that already has both must not pull an apt update
# along on their behalf. Their selectors (--git, --gh) force the work anyway.
git_needed=0
gh_needed=0
if [ $INSTALL_GIT -eq 1 ] && { [ $FORCE_REINSTALL -eq 1 ] || ! command -v git >/dev/null 2>&1; }; then
    git_needed=1
fi
if [ $INSTALL_GH -eq 1 ] && { [ $FORCE_REINSTALL -eq 1 ] || ! command -v gh >/dev/null 2>&1; }; then
    gh_needed=1
fi

# The full prerequisite set is only needed by the apt-installed components.
# Selecting just a per-user tool (--node) shouldn't drag an apt update along -
# that installer only needs curl.
if [ $HAS_APT -eq 1 ] && { [ $INSTALL_PHP -eq 1 ] || [ $INSTALL_COMPOSER -eq 1 ] \
   || [ $INSTALL_WPCLI -eq 1 ] || [ $git_needed -eq 1 ] || [ $gh_needed -eq 1 ]; }; then
    infra_info "Installing prerequisites..."
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        lsb-release \
        gnupg \
        curl \
        unzip \
        git >/dev/null
    infra_ok "Prerequisites installed"
elif ! command -v curl >/dev/null 2>&1; then
    if [ $HAS_APT -eq 1 ]; then
        infra_info "Installing curl..."
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl >/dev/null
        infra_ok "curl installed"
    else
        # Every remaining installer here is "curl a script and run it".
        infra_err "curl is required and not installed"
        case "$INFRA_OS" in
            macos)           printf '    xcode-select --install\n' >&2 ;;
            windows|gitbash) printf '    Git for Windows ships curl - reinstall it, or scoop install curl\n' >&2 ;;
            *)               printf '    install curl with your package manager, then re-run\n' >&2 ;;
        esac
        exit 1
    fi
fi

if [ $INSTALL_PHP -eq 1 ]; then
    if grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        infra_info "ondrej/php repository already present"
    else
        infra_info "Adding the ondrej/php repository..."
        add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || {
            infra_err "Failed to add ppa:ondrej/php"
            exit 1
        }
        infra_ok "Repository added"
    fi

    apt-get update -qq
fi

# ------------------------------------------------------------------ php builds

# Not every extension exists for every version, so filter against the real
# package index instead of letting one missing package fail the whole install.
packages_for() {
    local version="$1" ext pkg available=""
    for ext in $PHP_EXTENSIONS; do
        pkg="php${version}-${ext}"
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            available="$available $pkg"
        else
            infra_warn "skipping $pkg (not available)" >&2
        fi
    done
    printf '%s\n' "$available"
}

if [ $INSTALL_PHP -eq 1 ]; then
    for version in $PHP_VERSIONS; do
        infra_info "Installing PHP ${version}..."
        pkgs="$(packages_for "$version")"
        if [ -z "$pkgs" ]; then
            infra_err "No packages found for PHP ${version} - skipping"
            continue
        fi
        # shellcheck disable=SC2086
        apt-get install -y -qq $pkgs >/dev/null || {
            infra_err "PHP ${version} installation failed"
            exit 1
        }
        # Xdebug is installed but left off - "phpenmod -v <version> xdebug" turns it on
        if command -v phpdismod >/dev/null 2>&1; then
            phpdismod -v "$version" xdebug >/dev/null 2>&1 || true
        fi
        infra_ok "PHP ${version} installed"
    done
fi

# ---------------------------------------------------------------- php switcher

# phpsw only makes sense next to the PHP builds, so it follows the same gate.
# The heredoc below is left unindented on purpose - it is the script's source.
if [ $INSTALL_PHP -eq 1 ]; then

infra_info "Installing the phpsw version switcher..."
cat > "${BIN_DIR}/phpsw" << 'SWITCHER'
#!/usr/bin/env bash
#
# Switch the default PHP version (CLI + FPM).
#
#   phpsw          list installed versions
#   phpsw 8.2      switch to PHP 8.2

set -e

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; BLUE=''; NC=''
fi

installed_versions() {
    ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V
}

if [ -z "${1:-}" ]; then
    current="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
    echo "installed PHP versions:"
    for v in $(installed_versions); do
        if [ "$v" = "$current" ]; then
            printf '%b  * %s%b\n' "$GREEN" "$v" "$NC"
        else
            printf '    %s\n' "$v"
        fi
    done
    echo ""
    echo "usage: phpsw <version>"
    exit 0
fi

version="$1"
if [ ! -x "/usr/bin/php${version}" ]; then
    printf '%b%s%b\n' "$RED" "x PHP ${version} is not installed" "$NC" >&2
    echo "installed: $(installed_versions | tr '\n' ' ')" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

for binary in php phar phar.phar php-config phpize; do
    [ -x "/usr/bin/${binary}${version}" ] || continue
    update-alternatives --set "$binary" "/usr/bin/${binary}${version}" >/dev/null 2>&1 ||
        update-alternatives --install "/usr/bin/${binary}" "$binary" \
            "/usr/bin/${binary}${version}" 100 >/dev/null 2>&1 || true
done

# Keep only the selected FPM pool running so the socket path is predictable
if command -v systemctl >/dev/null 2>&1; then
    for v in $(installed_versions); do
        service="php${v}-fpm.service"
        systemctl list-unit-files "$service" >/dev/null 2>&1 || continue
        if [ "$v" = "$version" ]; then
            systemctl enable --now "$service" >/dev/null 2>&1 || true
            systemctl restart "$service" >/dev/null 2>&1 || true
        else
            systemctl disable --now "$service" >/dev/null 2>&1 || true
        fi
    done
else
    # WSL without systemd: no unit to enable, so drive the init script directly.
    for v in $(installed_versions); do
        [ -x "/etc/init.d/php${v}-fpm" ] || continue
        if [ "$v" = "$version" ]; then
            "/etc/init.d/php${v}-fpm" restart >/dev/null 2>&1 || true
        else
            "/etc/init.d/php${v}-fpm" stop >/dev/null 2>&1 || true
        fi
    done
fi

printf '%b%s%b\n' "$GREEN" "* now using $(php -v | head -1)" "$NC"
printf '%b%s%b\n' "$BLUE" "> fpm socket: /run/php/php${version}-fpm.sock" "$NC"
SWITCHER
chmod +x "${BIN_DIR}/phpsw"
infra_ok "phpsw installed"

infra_info "Setting PHP ${DEFAULT_VERSION} as the default..."
"${BIN_DIR}/phpsw" "$DEFAULT_VERSION"

fi

# -------------------------------------------------------------------- composer

# Composer and WP-CLI are PHP programs fetched from upstream, so they install
# the same way everywhere - they just need a php to run under, which on macOS
# and Windows is not this script's to provide.
if [ $INSTALL_COMPOSER -eq 1 ] && ! command -v php >/dev/null 2>&1; then
    skip_component Composer "no php on PATH to run it" "$SEL_COMPOSER"
    INSTALL_COMPOSER=0
fi

if [ $INSTALL_COMPOSER -eq 1 ]; then
    infra_info "Installing Composer..."
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"
    tmp="$(mktemp -d)"
    curl -fsSL https://getcomposer.org/installer -o "${tmp}/composer-setup.php"
    actual="$(php -r "echo hash_file('sha384', '${tmp}/composer-setup.php');")"
    if [ "$expected" != "$actual" ]; then
        rm -rf "$tmp"
        infra_err "Composer installer checksum mismatch - aborting"
        exit 1
    fi
    php "${tmp}/composer-setup.php" --quiet --install-dir="$BIN_DIR" --filename=composer
    rm -rf "$tmp"

    if [ "$NEEDS_ROOT" -eq 1 ]; then
        # Composer refuses to run plugins/scripts as root without this; dev box, so allow it
        cat > /etc/profile.d/composer.sh << 'EOF'
export COMPOSER_ALLOW_SUPERUSER=1
export PATH="$PATH:$HOME/.config/composer/vendor/bin:$HOME/.composer/vendor/bin"
EOF
        chmod 644 /etc/profile.d/composer.sh
    fi
    infra_ok "Composer installed"
fi

# ---------------------------------------------------------------------- wp-cli

if [ $INSTALL_WPCLI -eq 1 ] && ! command -v php >/dev/null 2>&1; then
    skip_component WP-CLI "no php on PATH to run it" "$SEL_WPCLI"
    INSTALL_WPCLI=0
fi

if [ $INSTALL_WPCLI -eq 1 ]; then
    infra_info "Installing WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o "${BIN_DIR}/wp-cli.phar"
    chmod +x "${BIN_DIR}/wp-cli.phar"

    # Wrapper so root doesn't have to remember --allow-root every single time
    cat > "${BIN_DIR}/wp" << EOF
#!/usr/bin/env bash
if [ "\$(id -u)" -eq 0 ]; then
    case " \$* " in
        *" --allow-root "*) ;;
        *) set -- --allow-root "\$@" ;;
    esac
fi
exec php "${BIN_DIR}/wp-cli.phar" "\$@"
EOF
    chmod +x "${BIN_DIR}/wp"
    infra_ok "WP-CLI installed"
fi

# ------------------------------------------------------------------- git / gh

# Both are install-when-missing: a box that already has them keeps the version
# it has, because upgrading someone's git out from under them is not this
# script's call. --git and --gh ask for the install regardless. Presence is
# re-checked here rather than reused from git_needed, since the prerequisite
# block above may already have pulled git in for the PHP path.

if [ $INSTALL_GIT -eq 1 ]; then
    if command -v git >/dev/null 2>&1 && [ $FORCE_REINSTALL -eq 0 ]; then
        infra_info "git already present ($(git --version 2>/dev/null))"
    elif [ $HAS_APT -eq 1 ]; then
        infra_info "Installing git..."
        apt-get install -y -qq git >/dev/null 2>&1 \
            && infra_ok "git installed ($(git --version 2>/dev/null))" \
            || infra_warn "git install failed - 'apt-get install git' by hand"
    elif infra_is_macos; then
        # Apple ships a git behind the Command Line Tools; Homebrew's is newer.
        if command -v brew >/dev/null 2>&1; then
            brew install git >/dev/null 2>&1 \
                && infra_ok "git installed ($(git --version 2>/dev/null))" \
                || infra_warn "brew install git failed"
        else
            infra_warn "install git with: xcode-select --install (or brew install git)"
        fi
    else
        infra_warn "install git with this platform's package manager"
    fi
fi

if [ $INSTALL_GH -eq 1 ]; then
    if command -v gh >/dev/null 2>&1 && [ $FORCE_REINSTALL -eq 0 ]; then
        infra_info "gh already present ($(gh --version 2>/dev/null | head -1))"
    elif [ $HAS_APT -eq 1 ]; then
        infra_info "Installing the GitHub CLI..."
        # Debian and Ubuntu ship a gh that trails upstream by a long way, so
        # prefer GitHub's own apt repo and keep the distro package as the
        # fallback - an unreachable key or a release the repo doesn't cover
        # should still leave the box with a working gh.
        gh_keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
        gh_list=/etc/apt/sources.list.d/github-cli.list
        if [ ! -s "$gh_keyring" ] || [ $FORCE_REINSTALL -eq 1 ]; then
            mkdir -p -m 755 /etc/apt/keyrings
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                -o "$gh_keyring" 2>/dev/null || true
            chmod go+r "$gh_keyring" 2>/dev/null || true
        fi
        if [ -s "$gh_keyring" ]; then
            printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
                "$(dpkg --print-architecture)" "$gh_keyring" > "$gh_list"
            chmod 644 "$gh_list"
            apt-get update -qq || true
        else
            rm -f "$gh_keyring" "$gh_list"
            infra_warn "could not fetch GitHub's apt key - using the distro gh package"
        fi

        if apt-get install -y -qq gh >/dev/null 2>&1; then
            infra_ok "gh installed ($(gh --version 2>/dev/null | head -1))"
        else
            # The repo is there but unusable for this release - drop it and take
            # whatever gh the distro has rather than leaving the box without one.
            rm -f "$gh_list"
            apt-get update -qq || true
            apt-get install -y -qq gh >/dev/null 2>&1 \
                && infra_ok "gh installed from the distro package ($(gh --version 2>/dev/null | head -1))" \
                || infra_warn "gh install failed - see https://cli.github.com"
        fi
    elif infra_is_macos && command -v brew >/dev/null 2>&1; then
        infra_info "Installing the GitHub CLI via Homebrew..."
        brew install gh >/dev/null 2>&1 \
            && infra_ok "gh installed ($(gh --version 2>/dev/null | head -1))" \
            || infra_warn "brew install gh failed - see https://cli.github.com"
    elif infra_is_windows && command -v winget >/dev/null 2>&1; then
        infra_info "Installing the GitHub CLI via winget..."
        winget install --id GitHub.cli --silent --accept-package-agreements >/dev/null 2>&1 \
            && infra_ok "gh installed - open a new shell to pick it up" \
            || infra_warn "winget install GitHub.cli failed - see https://cli.github.com"
    else
        infra_warn "no package manager for gh here - see https://cli.github.com"
    fi
fi

# ------------------------------------------------------------------ node / nvm

# nvm is a per-user tool: it installs into a home directory and runs from a
# login shell, so target the user who invoked sudo (not root) - that's whose
# shell will actually use it.

if [ $INSTALL_NODE -eq 1 ]; then
    infra_info "Installing Node via nvm..."

    # "20" and "--lts" both mean an install target; only "--lts" needs the
    # lts/* alias for a persistent default.
    if [ "$NODE_VERSION" = "--lts" ]; then
        node_default="lts/*"
    else
        node_default="$NODE_VERSION"
    fi

    if [ -s "$TOOL_HOME/.nvm/nvm.sh" ]; then
        infra_info "nvm already present for ${TOOL_USER}"
    else
        run_as_user 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >/dev/null 2>&1' \
            && infra_ok "nvm installed for ${TOOL_USER}" \
            || infra_warn "nvm install failed for ${TOOL_USER} - skipping Node"
    fi

    if [ -s "$TOOL_HOME/.nvm/nvm.sh" ]; then
        run_as_user "export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install ${NODE_VERSION} && nvm alias default '${node_default}'" >/dev/null 2>&1 \
            && infra_ok "Node ${NODE_VERSION} installed (default: ${node_default})" \
            || infra_warn "Node ${NODE_VERSION} installation failed"
    fi
fi

# -------------------------------------------------------------------- starship

# The prompt itself. On Linux it goes to /usr/local/bin rather than a home
# directory so every user on the box gets the same one and a root shell renders
# what the invoking user's does; elsewhere it is per-user like everything else.
# git.sh picks it up from PATH and keeps its own PS1 as the fallback, so neither
# half depends on the other.
if [ $INSTALL_STARSHIP -eq 1 ]; then
    infra_info "Installing starship..."
    starship_bin="${BIN_DIR}/starship"

    if [ -x "$starship_bin" ] && [ $FORCE_REINSTALL -eq 0 ]; then
        infra_info "starship already present"
    else
        # -y skips the confirmation prompt, -b picks the bin dir. The installer
        # writes nothing outside it - the shell wiring is git.sh's job. It has
        # builds for Linux, macOS and Windows, so the same call works on all.
        curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$BIN_DIR" >/dev/null 2>&1 \
            && infra_ok "starship installed" \
            || infra_warn "starship install failed - see https://starship.rs"
    fi

    # MSYS puts the .exe suffix on it; treat either as installed.
    starship_present=0
    if [ -x "$starship_bin" ] || [ -x "${starship_bin}.exe" ]; then
        starship_present=1
    fi

    # The config belongs to the user whose shell renders the prompt, not root.
    # A config already there is left alone unless --starship asked for a reset:
    # it is a file people tune, and clobbering it on every run would undo that.
    starship_toml="${TOOL_HOME}/.config/starship.toml"
    if [ -f "$starship_toml" ] && [ $FORCE_REINSTALL -eq 0 ]; then
        infra_info "starship config already at ${starship_toml}"
    elif [ $starship_present -eq 1 ]; then
        mkdir -p "${TOOL_HOME}/.config"
        # Directory and git branch, in the shape the old hand-rolled PS1 had:
        # user@host:/current/path (branch:status)$
        cat > "$starship_toml" << 'EOF'
# managed by infra install.sh - delete this line to keep your own edits
"$schema" = 'https://starship.rs/config-schema.json'

add_newline = false
format = "$username$hostname$directory$git_branch$git_status$character"

[username]
show_always = true
style_user = "green"
style_root = "red"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "green"
format = "[@$hostname]($style):"

[directory]
style = "blue"
truncate_to_repo = false
truncation_length = 0
format = "[$path]($style)"

[git_branch]
style = "yellow"
format = "[ \\($branch]($style)"

[git_status]
style = "yellow"
format = "[$all_status$ahead_behind\\)]($style)"
conflicted = "!"
untracked = "?"
modified = "*"
staged = "+"
renamed = "r"
deleted = "x"
stashed = "\\$"
ahead = "^${count}"
behind = "v${count}"
diverged = "^v"
up_to_date = ""

[character]
success_symbol = "[\\$](white)"
error_symbol = "[\\$](red)"
EOF
        chown "$TOOL_USER" "$starship_toml" 2>/dev/null || true
        infra_ok "starship config written to ${starship_toml}"
    fi

    # Machine-wide init. The per-user prompt is wired through git.sh, sourced
    # from ~/.bashrc - but a login shell reads ~/.profile, and the shells claude,
    # codex and other agents open often never source ~/.bashrc at all, so they
    # fall back to bash's default prompt with no directory or branch. A profile.d
    # drop-in runs for every interactive shell that reads /etc/profile (login
    # shells, most agent terminals) and starts starship there too. It is guarded
    # so it never double-inits when git.sh already ran, and is (re)written on
    # every run - it is managed, not a file people tune - so the fix lands even
    # when the user config above was left in place.
    #
    # Only where an /etc/profile.d exists and is ours to write: macOS has the
    # directory but nothing reads it, and MSYS has no such mechanism, so on both
    # the per-user wiring at the end of this script is the whole story.
    if [ $starship_present -eq 1 ] && [ "$NEEDS_ROOT" -eq 1 ] && [ -d /etc/profile.d ]; then
        cat > /etc/profile.d/starship.sh << 'EOF'
# managed by infra install.sh - machine-wide starship prompt for login and
# agent shells that never source a per-user ~/.bashrc. Edits are overwritten.
#
# Read by zsh too: Debian's /etc/zprofile sources /etc/profile, so this file has
# to know which shell it landed in. $ZSH_VERSION is the unambiguous answer -
# under sh emulation $0 is not the file and `declare` does not exist, so neither
# is safe to test. Each branch skips its own init when starship is already up,
# so a shell that also sources git.sh doesn't end up double-wrapped.
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if command -v starship >/dev/null 2>&1; then
    if [ -n "${ZSH_VERSION:-}" ]; then
        [ -n "${STARSHIP_SESSION_KEY:-}" ] || eval "$(starship init zsh)"
    else
        declare -F starship_precmd >/dev/null 2>&1 || eval "$(starship init bash)"
    fi
fi
EOF
        chmod 644 /etc/profile.d/starship.sh
        infra_ok "starship init written to /etc/profile.d/starship.sh"
    fi

    # Agents (claude, codex, ...) take over the whole terminal, so the shell
    # prompt never shows while you are inside one. Claude Code's statusLine runs
    # a command and renders its output at the bottom of that UI - point it at the
    # same starship render and the branch and path show inside the agent too.
    # The script sits next to starship.toml and is managed like it; the settings
    # merge is jq so the file's other keys (hooks, theme, ...) are untouched, and
    # it only writes when the statusLine is unset or already ours - a hand-tuned
    # one is left alone.
    if [ $starship_present -eq 1 ]; then
        statusline_sh="${TOOL_HOME}/.config/starship-statusline.sh"
        mkdir -p "${TOOL_HOME}/.config"
        cat > "$statusline_sh" << 'EOF'
#!/usr/bin/env bash
# managed by infra install.sh --starship - Claude Code statusLine that renders
# the starship prompt for the session's directory, so branch and path show
# inside the agent's UI. Overwritten on every --starship run.
input="$(cat)"
dir=""
command -v jq >/dev/null 2>&1 && dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[ -n "$dir" ] && [ -d "$dir" ] && cd "$dir" 2>/dev/null
command -v starship >/dev/null 2>&1 || exit 0
# Strip the \[ \] readline markers and the \$ the character module escapes for
# PS1 - a status line wants plain ANSI, not prompt escaping.
starship prompt 2>/dev/null | sed 's/\\\[//g; s/\\\]//g; s/\\[$]/$/g' | tr -d '\n'
EOF
        chmod 755 "$statusline_sh"
        chown "$TOOL_USER" "$statusline_sh" 2>/dev/null || true
        infra_ok "starship statusLine script written to ${statusline_sh}"

        claude_settings="${TOOL_HOME}/.claude/settings.json"
        if command -v jq >/dev/null 2>&1; then
            mkdir -p "${TOOL_HOME}/.claude"
            [ -f "$claude_settings" ] || printf '{}\n' > "$claude_settings"
            cur_sl="$(jq -r '.statusLine.command // ""' "$claude_settings" 2>/dev/null)"
            case "$cur_sl" in
                ""|*starship-statusline*)
                    tmp="$(mktemp)"
                    if jq --arg c '~/.config/starship-statusline.sh' \
                          '.statusLine = {type:"command", command:$c, padding:0}' \
                          "$claude_settings" > "$tmp" 2>/dev/null; then
                        mv "$tmp" "$claude_settings"
                        infra_ok "Claude Code statusLine now shows the starship prompt"
                    else
                        rm -f "$tmp"
                        infra_warn "could not update ${claude_settings} - set statusLine by hand"
                    fi ;;
                *)
                    infra_info "Claude Code already has a custom statusLine - left it alone" ;;
            esac
            chown "$TOOL_USER" "$claude_settings" 2>/dev/null || true
        else
            infra_warn "jq not found - skipped Claude statusLine wiring (install jq, then re-run --starship)"
        fi
    fi
fi

# Everything under ~ was written as root when running under sudo; hand it back.
if [ "$NEEDS_ROOT" -eq 1 ] && [ "$TOOL_USER" != root ]; then
    for owned in "${TOOL_HOME}/.config" "${TOOL_HOME}/.claude"; do
        [ -e "$owned" ] && chown -R "$TOOL_USER" "$owned" 2>/dev/null || true
    done
fi

# ------------------------------------------------------------------------ done

echo ""
infra_ok "Installation complete on $(platform_label)"
echo ""
# Report only what this run touched, and only with `if` - under `set -e` a
# trailing "[ test ] && echo" that tests false ends the script right here,
# before the shell integration below ever runs.
if [ $INSTALL_PHP -eq 1 ]; then
    echo "  php       $(php -v 2>/dev/null | head -1)"
fi
if [ $INSTALL_COMPOSER -eq 1 ]; then
    echo "  composer  $(COMPOSER_ALLOW_SUPERUSER=1 "${BIN_DIR}/composer" --version --no-ansi 2>/dev/null | head -1)"
fi
if [ $INSTALL_WPCLI -eq 1 ]; then
    echo "  wp        $("${BIN_DIR}/wp" --version 2>/dev/null | head -1)"
fi
if [ $INSTALL_NODE -eq 1 ]; then
    node_ver="$(run_as_user 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" 2>/dev/null; node --version' 2>/dev/null | tail -1)"
    if [ -n "$node_ver" ]; then
        echo "  node      ${node_ver} (via nvm)"
    fi
fi
if [ $INSTALL_GIT -eq 1 ] && command -v git >/dev/null 2>&1; then
    echo "  git       $(git --version 2>/dev/null)"
fi
if [ $INSTALL_GH -eq 1 ] && command -v gh >/dev/null 2>&1; then
    echo "  gh        $(gh --version 2>/dev/null | head -1)"
fi
if [ $INSTALL_STARSHIP -eq 1 ]; then
    # A per-user BIN_DIR may not be on PATH yet, so ask it by path when the name
    # doesn't resolve - the PATH warning further down is the fix for that.
    starship_bin="$(command -v starship 2>/dev/null || printf '%s' "${BIN_DIR}/starship")"
    if [ -x "$starship_bin" ]; then
        echo "  starship  $("$starship_bin" --version 2>/dev/null | head -1)"
    fi
fi
echo ""
if [ $INSTALL_PHP -eq 1 ]; then
    echo "  installed: $(ls -1 /usr/bin/php[0-9].[0-9] 2>/dev/null | sed 's#.*/php##' | sort -V | tr '\n' ' ')"
    echo "  switch:    phpsw <version>"
fi
if [ $INSTALL_NODE -eq 1 ]; then
    echo "  node:      nvm use <version>"
fi
echo ""

# ------------------------------------------------------------ shell integration

# Make the shell load git.sh (shortcuts, branch prompt, worktree helpers) in
# future sessions. The repo is resolved from this script's own location and the
# line goes into the invoking user's rc file - so it works wherever the checkout
# lives and for whoever ran it, not a fixed path.
#
# Which rc file is not one answer: bash on macOS opens a *login* shell for every
# Terminal window and never reads ~/.bashrc, and zsh - the macOS default since
# Catalina - reads neither. Write to every file this user's shell will actually
# open, and let the grep guard keep it to one line each.
rc_files() { platform_rc_files "$TOOL_HOME" "$TOOL_SHELL"; }

GIT_SH="${INFRA_DIR}/git.sh"
if [ -f "$GIT_SH" ]; then
    src_line="[ -f \"$GIT_SH\" ] && source \"$GIT_SH\""
    # A hand-written or older line may source the same file through $HOME rather
    # than the absolute path - match that form too, or every run appends a second
    # copy that grep for the absolute path never sees. Keep the literal $HOME.
    case "$GIT_SH" in
        "$TOOL_HOME"/*) GIT_SH_HOME="\$HOME/${GIT_SH#"$TOOL_HOME"/}" ;;
        *)              GIT_SH_HOME="$GIT_SH" ;;
    esac
    # An earlier install may have written a commands.sh line for a file that no
    # longer exists - drop it rather than leaving a dead source in the rc file.
    old_line="${INFRA_DIR}/commands.sh"
    for rc in $(rc_files); do
        touch "$rc"
        if grep -qF "$old_line" "$rc" 2>/dev/null; then
            tmp="$(mktemp)" && grep -vF "$old_line" "$rc" > "$tmp" && mv "$tmp" "$rc"
        fi
        grep -qF "$GIT_SH" "$rc" 2>/dev/null \
            || grep -qF "$GIT_SH_HOME" "$rc" 2>/dev/null \
            || printf '%s\n' "$src_line" >> "$rc"
        chown "$TOOL_USER" "$rc" 2>/dev/null || true
        infra_ok "${rc} will auto-load git.sh"
    done
else
    infra_warn "no git.sh next to install.sh - skipping shell integration"
fi

# A per-user BIN_DIR is no use if nothing looks in it.
case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)  infra_warn "${BIN_DIR} is not on your PATH - add it:"
        printf '    echo '\''export PATH="%s:$PATH"'\'' >> %s\n' \
            "$BIN_DIR" "$(rc_files | head -1)" ;;
esac

# Auto-reload the shell so the new environment is live right away. A script
# can't mutate its parent shell, so the closest thing is to exec a fresh login
# shell for the invoking user - it re-reads the rc file and thus sources git.sh.
# Only under sudo, where the shell we would return to is the wrong user's, and
# only interactively so non-interactive/CI runs still return.
if [ "$NEEDS_ROOT" -eq 1 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && [ -t 0 ] && [ -t 1 ]; then
    infra_info "Reloading the shell so the helpers and new tools are ready..."
    exec su - "$SUDO_USER"
else
    infra_warn "Open a new shell (or 'source ${GIT_SH:-./git.sh}') to pick up the environment"
fi
