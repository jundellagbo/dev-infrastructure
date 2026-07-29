# Git shortcuts, the branch prompt and the worktree helpers.
#
# Source this file directly; install.sh wires it into the rc files the user's
# shell actually reads. It runs under bash on Linux, WSL, macOS and Git Bash,
# and under zsh - which is the macOS default login shell, so a bash-only file
# here would mean a Mac with no prompt and no worktree helpers.
#
# Anything that differs per platform comes from platforms/platform.sh next to
# this file: docker's argument mangling under MSYS, how to escalate, how to read
# a file's timestamp. Its names are all infra_*/platform_*/INFRA_*, so nothing
# it defines can collide with something a user might type at this prompt.

# Which shell is reading this. Both are supported; the differences are the
# prompt hook, the keybinding builtin and array syntax, all near the bottom.
if [ -n "${ZSH_VERSION:-}" ]; then
    INFRA_SHELL=zsh
else
    INFRA_SHELL=bash
fi

# This file's own directory. In bash that is BASH_SOURCE; in zsh a sourced
# file's $0 is the file itself, which is why this needs no zsh-only expansion
# (one would be a parse error in bash, whether or not the branch ever runs).
if [ -n "${BASH_SOURCE:-}" ]; then
    _INFRA_GIT_SH="${BASH_SOURCE[0]}"
else
    _INFRA_GIT_SH="$0"
fi
_INFRA_GIT_SH="$(cd "$(dirname "$_INFRA_GIT_SH")" && pwd)/$(basename "$_INFRA_GIT_SH")"

# Optional: a checkout that only has git.sh still gets every alias and helper,
# it just falls back to plain docker and plain sudo.
if [ -r "$(dirname "$_INFRA_GIT_SH")/platforms/platform.sh" ]; then
    . "$(dirname "$_INFRA_GIT_SH")/platforms/platform.sh"
else
    platform_docker() { docker "$@"; }
fi

# Commit
alias gcom='git commit -m'
alias gamend='git commit --amend'
alias gundo='git reset --soft HEAD~1'

# Status / Diff
alias gst='git status -sb'
alias gdf='git diff'
alias gdfc='git diff --cached'

# Branching
alias gbr='git branch'
alias gch='git fetch && git checkout'
alias gnb='function _gnb(){ git checkout -b "$1" && git push -u origin "$1"; }; _gnb'
alias gdel='git branch -d'

# Worktrees
#
#   gwtadd <branch> [base] [path] [--no-push]
#                            add a worktree (base defaults to origin's default
#                            branch, path defaults to ../<branch>). A branch it
#                            creates is pushed to origin with -u; --no-push
#                            keeps it local.
#   gwtls                    list worktrees
#   gwtcd <branch>           jump into a worktree
#   gwtrm <branch> [opts]    tear a worktree down (docker + dir + local/remote branch)
#   gwtprune                 prune stale worktree metadata
#
# Worktrees live next to the repo in "../<slug>" unless GIT_WORKTREE_DIR is set
# or an explicit path is passed to gwtadd.

_gwt_root() { git rev-parse --show-toplevel 2>/dev/null; }

_gwt_base_dir() {
  local root
  root="$(_gwt_root)"
  if [ -z "$root" ]; then
    echo "not inside a git repository" >&2
    return 1
  fi
  if [ -n "$GIT_WORKTREE_DIR" ]; then
    printf '%s\n' "${GIT_WORKTREE_DIR%/}"
  else
    printf '%s\n' "$(dirname "$root")"
  fi
}

# feature/login -> feature-login (safe as a directory name)
_gwt_slug() { printf '%s\n' "${1//\//-}"; }

# origin's default branch (master, main, ...), falling back to the current one
_gwt_default_branch() {
  local head
  head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  head="${head#origin/}"
  [ -n "$head" ] || head="$(git branch --show-current 2>/dev/null)"
  printf '%s\n' "$head"
}

# Path of the worktree holding <branch>, if any
_gwt_path_of() {
  git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$1" '
    /^worktree /  { path = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == want) { print path; exit } }
  '
}

_gwtadd() {
  local branch="" base="" path="" root base_dir start want_push=1
  local usage="usage: gwtadd <branch> [base-branch] [path] [--no-push]   e.g. gwtadd feature/login master-upgrade ../login"

  # Positional order is unchanged - the flags just get picked out of the line,
  # so every existing "gwtadd feature/x master ../x" still means what it did.
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-push)  want_push=0 ;;
      --push)     want_push=1 ;;   # the default; accepted so it can be explicit
      -h|--help)  echo "$usage"; return 0 ;;
      -*)         echo "unknown option: $1" >&2; return 1 ;;
      *)
        if   [ -z "$branch" ]; then branch="$1"
        elif [ -z "$base" ];   then base="$1"
        elif [ -z "$path" ];   then path="$1"
        else echo "too many arguments: $1" >&2; return 1
        fi ;;
    esac
    shift
  done

  if [ -z "$branch" ]; then
    echo "$usage" >&2
    return 1
  fi

  root="$(_gwt_root)" || return 1
  if [ -n "$path" ]; then
    # Explicit path: a trailing "/" (or an existing dir) means "put it in here"
    case "$path" in
      */) path="${path%/}/$(_gwt_slug "$branch")" ;;
      *)  if [ -d "$path" ]; then path="${path}/$(_gwt_slug "$branch")"; fi ;;
    esac
    base_dir="$(dirname "$path")"
  else
    base_dir="$(_gwt_base_dir)" || return 1
    path="${base_dir}/$(_gwt_slug "$branch")"
  fi

  if [ -e "$path" ]; then
    echo "path already exists: $path" >&2
    return 1
  fi

  git fetch --prune origin || return 1
  [ -n "$base" ] || base="$(_gwt_default_branch)"
  mkdir -p "$base_dir" || return 1

  local created=0
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    # Branch already exists locally - just check it out somewhere new
    git worktree add "$path" "$branch" || return 1
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git worktree add --track -b "$branch" "$path" "origin/$branch" || return 1
  else
    # New branch: prefer the remote tip of the base so we branch off fresh code
    start="$base"
    git show-ref --verify --quiet "refs/remotes/origin/$base" && start="origin/$base"
    if ! git show-ref --verify --quiet "refs/heads/$base" && [ "$start" = "$base" ]; then
      echo "base branch not found: $base" >&2
      return 1
    fi
    echo "branching $branch off $start"
    git worktree add -b "$branch" "$path" "$start" || return 1
    created=1
  fi

  # Publish a branch this command just invented: without it there is no upstream
  # for the first push, nothing for teammates or CI to see, and nothing for
  # gwtrm to delete on the remote. Only the branch we created - re-checking out
  # something that already exists locally or on origin pushes nothing.
  if [ $want_push -eq 1 ] && [ $created -eq 1 ] && git remote get-url origin >/dev/null 2>&1; then
    if ! git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
      echo "pushing $branch to origin"
      # A push can fail for reasons that say nothing about the worktree - no
      # network, no write access, a hook on the server. The checkout is still
      # exactly what was asked for, so keep it and name the retry.
      if ! git -C "$path" push -u origin "$branch"; then
        echo "push failed - worktree is ready, branch is local only" >&2
        echo "  retry with: git -C '$path' push -u origin '$branch'" >&2
      fi
    fi
  fi

  # Untracked env files never come along with the checkout - carry them over
  local f
  for f in .env .env.local; do
    [ -f "${root}/${f}" ] && [ ! -e "${path}/${f}" ] && cp "${root}/${f}" "${path}/${f}"
  done

  echo "worktree ready: $path"
  cd "$path" || return 1
}

# Compose project name docker derives from a directory (lowercase, alnum/_/- only)
_gwt_compose_project() {
  local name
  # tr, not ${name,,}: that expansion is bash 4+, and macOS ships bash 3.2 -
  # a syntax error here would break sourcing this whole file.
  name="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "${name//[^a-z0-9_-]/}"
}

# platform_docker, not docker: under MSYS every argument that looks like a Unix
# path is rewritten to a Windows one before docker sees it, which turns a label
# filter into nonsense and silently matches nothing.
_gwt_docker_cleanup() {
  local path="$1" proj file ids
  command -v docker >/dev/null 2>&1 || return 0
  proj="$(_gwt_compose_project "$path")"

  for file in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "${path}/${file}" ]; then
      echo "docker compose down (${proj})"
      ( cd "$path" && platform_docker compose -f "$file" -p "$proj" down --volumes --rmi local --remove-orphans )
      break
    fi
  done

  # Sweep anything compose left behind (orphans from renamed/removed services).
  #
  # One id per invocation rather than splatting an unquoted "$ids" onto the
  # command line: zsh does not word-split unquoted expansions the way bash does,
  # so a multi-line list would arrive as a single argument and match nothing.
  local label="label=com.docker.compose.project=${proj}"
  _gwt_docker_each "$(platform_docker ps -aq --filter "$label" 2>/dev/null)"        rm -f
  _gwt_docker_each "$(platform_docker volume ls -q --filter "$label" 2>/dev/null)"  volume rm -f
  _gwt_docker_each "$(platform_docker images -q --filter "$label" 2>/dev/null)"     rmi -f
  _gwt_docker_each "$(platform_docker network ls -q --filter "$label" 2>/dev/null)" network rm
  return 0
}

# Run "docker <args...> <id>" once per id in a newline-separated list. Best
# effort throughout: an id another sweep already removed is not an error.
_gwt_docker_each() {
  local ids="$1" id
  shift
  [ -n "$ids" ] || return 0
  printf '%s\n' "$ids" | while IFS= read -r id; do
    [ -n "$id" ] && platform_docker "$@" "$id" >/dev/null 2>&1
  done
  return 0
}

# Remove a directory for real. Containers write into a bind-mounted worktree as
# root, so a plain `rm -rf` there dies with "Permission denied" and leaves the
# tree half-gone; escalate rather than reporting a cleanup that didn't happen.
_gwt_rm_tree() {
  local path="$1"
  [ -n "$path" ] && [ -e "$path" ] || return 0

  rm -rf "$path" 2>/dev/null
  [ -e "$path" ] || return 0

  # Our own files, just written read-only (node_modules, vendor, .git objects)
  chmod -R u+rwX "$path" 2>/dev/null
  rm -rf "$path" 2>/dev/null
  [ -e "$path" ] || return 0

  if command -v sudo >/dev/null 2>&1; then
    # Passwordless first so scripts and hooks never block on a prompt
    sudo -n rm -rf "$path" 2>/dev/null
    [ -e "$path" ] || return 0
    if [ -t 0 ]; then
      echo "root-owned files left in $path - sudo needed to remove them"
      sudo rm -rf "$path"
      [ -e "$path" ] || return 0
    fi
  else
    # No sudo at all: on Git Bash what blocks a delete is usually a file another
    # process still has open - an editor, a running container - rather than an
    # owner this shell can't beat, so escalating would not have helped anyway.
    echo "could not remove $path - close anything using it, or delete it as Administrator" >&2
    return 1
  fi

  echo "could not remove $path (permission denied) - remove it manually: sudo rm -rf '$path'" >&2
  return 1
}

# codebase-memory-mcp indexes a repo by its working-directory path, so a worktree
# that was indexed is its own project keyed by the worktree path - deleting the
# tree leaves that index behind, pointing at files that no longer exist. These
# helpers find and drop it through the tool's own CLI. Both are best-effort: the
# tool may not be installed, and a memory-index hiccup must never block a
# teardown, so nothing here returns non-zero into gwtrm's flow.
_gwt_cbm_bin() { command -v codebase-memory-mcp 2>/dev/null; }

# True when an index exists for exactly this worktree path. list_projects prints
# JSON holding each project's absolute path, so a literal match on the quoted
# path is enough and needs no JSON parser.
_gwt_cbm_has_index() {
  local path="$1" bin
  [ -n "$path" ] || return 1
  bin="$(_gwt_cbm_bin)" || return 1
  "$bin" cli list_projects '{}' 2>/dev/null | grep -qF "\"$path\""
}

_gwt_cbm_cleanup() {
  local path="$1" bin
  [ -n "$path" ] || return 0
  bin="$(_gwt_cbm_bin)" || return 0
  if "$bin" cli delete_project --project "$path" >/dev/null 2>&1; then
    echo "removed codebase-memory index for $path"
  fi
}

_gwtrm() {
  local branch="" want_path="" force=0 assume_yes=0 skip_docker=0 keep_branch=0 keep_remote=0
  local usage="usage: gwtrm <branch> [path] [-f] [-y] [--no-docker] [--keep-branch] [--keep-remote]"
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)    force=1 ;;
      -y|--yes)      assume_yes=1 ;;
      --no-docker)   skip_docker=1 ;;
      --keep-branch) keep_branch=1 ;;
      --keep-remote) keep_remote=1 ;;
      -h|--help)
        echo "$usage"
        return 0 ;;
      -*) echo "unknown option: $1" >&2; return 1 ;;
      *)  if [ -z "$branch" ]; then branch="$1"; else want_path="$1"; fi ;;
    esac
    shift
  done

  if [ -z "$branch" ]; then
    echo "$usage" >&2
    return 1
  fi

  local root path has_remote=0 remote_stale=0 remote_offline=0 has_cbm=0
  root="$(_gwt_root)" || return 1
  if [ -n "$want_path" ]; then
    if [ ! -d "$want_path" ]; then
      echo "worktree path not found: $want_path" >&2
      return 1
    fi
    path="$(cd "$want_path" && pwd)"
  else
    path="$(_gwt_path_of "$branch")"
  fi
  if [ -z "$path" ]; then
    # Fall back to the current directory when we're standing inside the worktree
    path="$PWD"
    [ "$path" != "$root" ] && [ -e "${path}/.git" ] || path=""
  fi
  # Did anything index this worktree? Checked now so the preview can list it.
  _gwt_cbm_has_index "$path" && has_cbm=1

  # Ask origin itself. refs/remotes/origin/<branch> only says what the last
  # fetch saw: missing there (never fetched) is why a delete used to be skipped
  # silently, and present-but-stale is a tracking ref to clean up, not a push.
  git show-ref --verify --quiet "refs/remotes/origin/$branch" && remote_stale=1
  if git remote get-url origin >/dev/null 2>&1; then
    # GIT_TERMINAL_PROMPT=0: on a private remote with no cached credentials this
    # probe would sit on a username prompt. Failing fast is right - it falls
    # through to the tracking ref like any other unreachable origin.
    GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
    case $? in
      0) has_remote=1; remote_stale=0 ;;
      2) has_remote=0 ;;                                  # origin answered: not there
      *) has_remote=$remote_stale; remote_stale=0; remote_offline=1 ;;
    esac
  fi

  echo "about to remove:"
  [ -n "$path" ] && echo "  worktree      $path"
  [ $skip_docker -eq 0 ] && [ -n "$path" ] && echo "  docker        containers/volumes/images/networks for $(_gwt_compose_project "$path")"
  [ $has_cbm -eq 1 ] && echo "  cbm index     codebase-memory index for $path"
  [ $keep_branch -eq 0 ] && echo "  local branch  $branch"
  if [ $keep_remote -eq 0 ] && [ $has_remote -eq 1 ]; then
    if [ $remote_offline -eq 1 ]; then
      echo "  remote branch origin/$branch  (irreversible; origin unreachable - delete may fail)"
    else
      echo "  remote branch origin/$branch  (irreversible)"
    fi
  fi

  if [ $assume_yes -eq 0 ]; then
    # printf then a bare read: -p is bash's spelling and zsh wants
    # `read "reply?prompt"` instead, so neither shell's version is portable.
    local reply
    printf 'proceed? [y/N] '
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; return 1 ;; esac
  fi

  # Don't saw off the branch we're sitting on
  case "$PWD/" in "${path%/}/"*) cd "$root" || return 1 ;; esac

  [ $skip_docker -eq 0 ] && [ -n "$path" ] && _gwt_docker_cleanup "$path"

  if [ -n "$path" ]; then
    if [ $force -eq 1 ]; then
      git worktree remove --force "$path" 2>/dev/null
    else
      # git refuses on a dirty tree, but it also refuses when it can't unlink a
      # root-owned file - only the first case is the user's to resolve.
      if ! git worktree remove "$path" 2>/dev/null && [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
        echo "worktree is dirty - re-run with -f to discard it" >&2
        return 1
      fi
    fi
    # git's own remove is best-effort here: whatever it left behind (docker
    # bind-mount leftovers, root-owned build output) still has to go.
    _gwt_rm_tree "$path" || return 1
  fi
  # Drops the now-dangling .git/worktrees/<name> admin directory as well
  git worktree prune

  # The tree is gone; drop its codebase-memory index so it stops pointing at
  # files that no longer exist. Best-effort - never fails the teardown.
  [ $has_cbm -eq 1 ] && _gwt_cbm_cleanup "$path"

  if [ $keep_branch -eq 0 ] && git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch -D "$branch"
  fi

  local rc=0
  if [ $keep_remote -eq 0 ] && [ $has_remote -eq 1 ]; then
    if git push origin --delete "$branch"; then
      # The push leaves the tracking ref behind when it was created locally
      git update-ref -d "refs/remotes/origin/$branch" 2>/dev/null
    else
      echo "failed to delete origin/$branch - retry with: git push origin --delete '$branch'" >&2
      rc=1
    fi
  elif [ $keep_remote -eq 0 ] && [ $remote_stale -eq 1 ]; then
    # Already gone on origin; drop the tracking ref so it stops showing up
    git update-ref -d "refs/remotes/origin/$branch" 2>/dev/null
    echo "origin/$branch was already gone - dropped the stale tracking ref"
  fi

  [ $rc -eq 0 ] && echo "cleaned up: $branch"
  return $rc
}

alias gwtadd='_gwtadd'
alias gwtrm='_gwtrm'
alias gwtls='git worktree list'
alias gwtprune='git worktree prune -v'
alias gwtcd='function _gwtcd(){ cd "$(_gwt_base_dir)/$(_gwt_slug "$1")"; }; _gwtcd'

# Pull / Push
alias gpull='git pull origin'
alias gpush='git push -u origin'
alias gpf='git push --force-with-lease'

# Merge / Rebase
alias gmg='git merge'
alias grb='git rebase'
alias grbi='git rebase -i'

# Logs
alias glg='git log --oneline --graph --decorate --all'
alias glast='git log -1 HEAD'
alias gtree='git log --graph --pretty=format:"%C(auto)%h%d %s %Cgreen(%cr) %C(bold blue)<%an>" --abbrev-commit --date=relative'

# Cleanup
alias gwipe='git reset --hard && git clean -fd'

# Who wrote what
alias gwho='git shortlog -s --'

# Project tooling
alias sail='./vendor/bin/sail'

# Git branch in the prompt - the fallback, used when starship isn't installed.
#
# The accumulator is `state`, not `status`: in zsh `status` is a special
# parameter tied to $?, so a local of that name is at best meaningless and at
# worst an error every time the prompt draws.
git_branch() {
  local branch state=""

  branch=$(git branch --show-current 2>/dev/null) || return

  # Staged changes
  git diff --cached --quiet 2>/dev/null || state="${state}+"

  # Unstaged changes
  git diff --quiet 2>/dev/null || state="${state}*"

  # Untracked files
  [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ] && state="${state}?"

  # Merge conflicts
  [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ] && state="${state}x"

  # Clean repo
  [ -z "$state" ] && state="✓"

  echo " ($branch:$state)"
}

# Is this an interactive shell? Both shells put i in $-, and both are asked the
# same way here so the prompt work is skipped identically in a script.
_infra_interactive() { case "$-" in *i*) return 0 ;; *) return 1 ;; esac; }

# Is starship already running in this shell? A login shell may have had it
# started by the machine-wide /etc/profile.d/starship.sh install.sh drops, and a
# second `starship init` would double-wrap the prompt hook.
_infra_starship_up() {
  if [ "$INFRA_SHELL" = zsh ]; then
    [ -n "${STARSHIP_SESSION_KEY:-}" ]
  else
    declare -F starship_precmd >/dev/null 2>&1
  fi
}

# The prompt: starship when it is installed (install.sh puts it on PATH and
# writes the config), the hand-rolled fallback otherwise. Both show the same
# thing - current directory and branch - so a machine without starship is not a
# machine with a worse prompt, and neither half depends on the other.
#
# The fallback prompt is written twice because the escape syntax is genuinely
# different: bash uses \u\h\w and brackets non-printing runs with \[ \], zsh
# uses %n%m%~ and %{ %}. Sharing one string would render the other's escapes
# literally.
if _infra_interactive; then
  if command -v starship >/dev/null 2>&1; then
    _infra_starship_up || eval "$(starship init "$INFRA_SHELL")"
  elif [ "$INFRA_SHELL" = zsh ]; then
    setopt PROMPT_SUBST 2>/dev/null
    PS1='%{%F{green}%}%n@%m%{%f%}:%{%F{blue}%}%~%{%F{yellow}%}$(git_branch)%{%f%}$ '
  else
    PS1='\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[33m\]$(git_branch)\[\e[0m\]\$ '
  fi
fi

# ------------------------------------------------------ reload when this changes

# A shell sources this file once, at startup, and then runs whatever it read for
# as long as it stays open - so an edit here reaches every terminal opened later
# and none of the ones already running. That is the stale copy people hit after
# changing an alias: the new shell has it, the shell they are standing in does
# not. Comparing the file's stamp before each prompt closes that gap; the shell
# re-sources itself on the next prompt after the checkout changes.
#
# llm.sh in llm-infrastructure does the same for itself. Neither file loads the
# other, so each watches its own and the names are kept apart deliberately -
# infra-reload over there is llm.sh's, and defining it here again would just
# shadow whichever loaded first.
#
# _INFRA_GIT_SH is resolved at the top of this file, where both shells can be
# asked for it in a way the other can still parse.

# Sub-second precision, and whole seconds are not enough: two changes in the same
# second read as one stamp, and since the stamp is only refreshed on reload, a
# change landing in the same second as the last one compares equal forever - the
# edit is missed permanently, not just until the next prompt.
#
# GNU stat's %.9Y is Linux, WSL and Git Bash (whose coreutils are GNU); BSD
# stat's %Fm is macOS. Both carry the fraction. ls does not, so the last
# fallback - a system with neither - keeps the coarse whole-second behaviour.
_infra_git_stamp() {
  stat -c %.9Y "$_INFRA_GIT_SH" 2>/dev/null \
    || stat -f %Fm "$_INFRA_GIT_SH" 2>/dev/null \
    || ls -l "$_INFRA_GIT_SH" 2>/dev/null
}
INFRA_GIT_STAMP="$(_infra_git_stamp)"

# Re-source when the stamp moved. Quiet by default - a shell that reloads on
# every edit should not narrate it.
#
# $? is captured first and handed back untouched: this runs inside
# PROMPT_COMMAND, where anything that returns a status of its own overwrites the
# one the prompt is about to render, and starship reads it to colour the final
# character. A hook that reports on the last command must not become the last
# command.
_infra_git_reload_if_changed() {
  local rc=$? now
  now="$(_infra_git_stamp)"
  if [ -n "$now" ] && [ "$now" != "$INFRA_GIT_STAMP" ]; then
    INFRA_GIT_STAMP="$now"
    . "$_INFRA_GIT_SH"
  fi
  return $rc
}

# Reload now, whether or not anything changed - for a shell opened before this
# hook existed, or when no prompt hook runs. --all bumps the file's stamp so
# every other open terminal reloads at its next prompt.
infra-git-reload() {
  . "$_INFRA_GIT_SH" && printf '  reloaded %s\n' "$_INFRA_GIT_SH"
  if [ "${1:-}" = "--all" ]; then
    touch "$_INFRA_GIT_SH" 2>/dev/null
    # After the touch, so this shell doesn't reload itself again on next prompt
    INFRA_GIT_STAMP="$(_infra_git_stamp)"
    printf '  other shells reload at their next prompt\n'
  fi
}

# Register the reload hook with whatever this shell calls its pre-prompt hook.
# Both shells have one and neither understands the other's: bash runs a string
# in PROMPT_COMMAND, zsh runs every function named in the precmd_functions
# array. The zsh branch is eval'd so bash never parses its array syntax.
#
# After starship, never before: its init moves any existing PROMPT_COMMAND into
# STARSHIP_PROMPT_COMMAND and runs it from inside its own precmd, so a hook
# added first would end up there and the check below would add a second copy.
# Appending also leaves starship's own hook first, which is where it has to be
# to read the real exit status.
if _infra_interactive; then
  if [ "$INFRA_SHELL" = zsh ]; then
    eval '
      typeset -ag precmd_functions
      (( ${precmd_functions[(I)_infra_git_reload_if_changed]} )) ||
        precmd_functions+=(_infra_git_reload_if_changed)
    '
  else
    case ";${PROMPT_COMMAND-};${STARSHIP_PROMPT_COMMAND-};" in
      *";_infra_git_reload_if_changed;"*) ;;
      ";;;"|";;") PROMPT_COMMAND="_infra_git_reload_if_changed" ;;
      *) PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND};}_infra_git_reload_if_changed" ;;
    esac
  fi
fi

# Up/down search the history for what has already been typed rather than walking
# it blindly. bash binds through readline, zsh through zle - and in a
# non-interactive shell neither line editor is loaded, so `bind` there prints a
# warning about line editing not being enabled for no reason at all.
if _infra_interactive; then
  if [ "$INFRA_SHELL" = zsh ]; then
    bindkey '^[[A' history-beginning-search-backward 2>/dev/null
    bindkey '^[[B' history-beginning-search-forward 2>/dev/null
  else
    bind '"\e[A": history-search-backward' 2>/dev/null
    bind '"\e[B": history-search-forward' 2>/dev/null
  fi
fi
