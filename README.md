# Development Infrastructure

**A local development stack** — Docker services for `*.dev.local`, the host
tooling that talks to them, and the shell helpers that make working across
repositories quick.

Three independent parts — use one, two, or all three:

| Part | What it is | Entry point |
| ---- | ---------- | ----------- |
| **Docker stack** | Nginx, Apache, PHP 7.4-8.4, MySQL, PostgreSQL, Redis, Adminer, MailHog, wildcard SSL and DNS for `*.dev.local` | `docker compose up -d` |
| **Host tooling** | Host PHP versions + switcher, Composer, WP-CLI, Node via nvm, git, the GitHub CLI, the starship prompt | `sudo ./install.sh` |
| **Shell helpers** | Git shortcuts, the prompt, reload-on-change, and worktree create/teardown | `source git.sh` |

```bash
sudo ./install.sh                   # host tooling + shell integration
source /path/to/infra/git.sh        # shell helpers: git shortcuts + worktrees
docker compose up -d                # start the stack
```

---

## The Docker stack

**Quick start.** If Apache, Nginx, MySQL or PostgreSQL are installed on the host,
clear them out first with `sudo ./scripts/uninstall-local-services.sh`. Then
generate the wildcard certificate (`./scripts/generate-ssl.sh` — it prints how to
trust the CA, which Windows needs), optionally point `WWW_PATH` / `NGINX_PATH` in
`.env` somewhere else (relative paths resolve from the repo), and start it with
`docker compose up -d`. Create a site with `./scripts/project-create.sh mysite`
and visit `https://mysite.dev.local`.

**Host DNS.** Containers resolve `*.dev.local` themselves; your browser does not.
On Linux with systemd-resolved, `sudo ./scripts/setup-host-dns.sh` installs a
persistent wildcard resolver pointing at `127.0.0.1`, so new virtual hosts need
no hosts-file entry. Elsewhere, add one hosts line per site — hosts files don't
support wildcards.

**Automatic virtual hosts.** Any directory named `www/<name>.dev.local/public` is
served at `https://<name>.dev.local` with no Nginx config and no reload. Files in
`NGINX_PATH` can still define explicit `server_name` hosts when a project needs
custom routing, and an exact name beats the wildcard host. The `nginx/` folder is
watched by the `config-watcher` container, so adding, changing or deleting a
config reloads Nginx automatically.

**Services and credentials.** MySQL and PostgreSQL both use `root` /
`artisan7530`, on 3306 and 5432. Adminer is at http://localhost:8081 (add
`?driver=pgsql` for Postgres; SQL imports up to 128 MB — after editing
`docker/adminer/.user.ini`, run `docker compose up -d --force-recreate adminer`).
All PHP mail goes to MailHog: SMTP `mailhog:1025` from containers, web UI at
http://localhost:8025. The default site is https://dev.local and Apache is
reachable directly at http://localhost:8080.

```bash
mysql -h 127.0.0.1 -u root -partisan7530          # from the host
docker compose exec mysql mysql -u root -partisan7530
psql -h 127.0.0.1 -U root -d postgres
docker compose exec postgresql psql -U root -d postgres
```

**Everyday commands.**

```bash
docker compose up -d                  # start        docker compose down    # stop
docker compose logs -f [service]      # logs         docker compose restart nginx
docker compose exec php composer install
docker compose exec php wp --path=/var/www/mysite/public plugin list
docker compose exec php bash
```

**PHP version.** Set `PHP_VERSION` in `.env` (7.4, 8.0-8.4), then
`docker compose build php && docker compose up -d php` and check with
`docker compose exec php php -v`. The image carries every extension WordPress
wants — mysqli, curl, dom, exif, fileinfo, intl, mbstring, xml, zip, gd (WebP),
bcmath, filter, iconv, sodium, imagick — plus caching (opcache, redis, apcu,
memcached, igbinary), database drivers (pdo, pdo_mysql, pdo_pgsql, pgsql) and
soap, pcntl, sockets, bz2, xsl, gettext, gmp, tidy, calendar.

**WordPress** in one project:

```bash
mkdir -p www/myblog/public
docker compose exec php sh -c "cd /var/www/myblog/public && wp core download --allow-root"
docker compose exec mysql mysql -u root -partisan7530 -e "CREATE DATABASE myblog;"
docker compose exec php wp --path=/var/www/myblog/public core install \
  --url=https://myblog.dev.local --title="My Blog" --admin_user=admin \
  --admin_password=password --admin_email=admin@example.com --allow-root
```

**Layout.** `docker/` holds the PHP and Apache images and vhosts, `nginx/` the
virtual host configs (default `NGINX_PATH`), `www/` the projects (default
`WWW_PATH`), `ssl/` the wildcard certificates, `mysql/` and `postgresql/` their
init scripts, and `scripts/` the helpers.

**SSL.** The certificate covers `*.dev.local`, `dev.local` and `localhost`. On
Windows, open `\\wsl$\Ubuntu\home\<you>\infra\ssl`, double-click `ca.crt` →
Install Certificate → Local Machine → Trusted Root Certification Authorities,
then restart the browser. Or in an elevated PowerShell:

```powershell
Import-Certificate -FilePath "\\wsl$\Ubuntu\home\<you>\infra\ssl\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

**Troubleshooting.** A port already in use: `sudo lsof -i :80`, then stop that
process or change the port in `docker-compose.yml`. Permission trouble in the
project tree: `sudo chown -R $USER:$USER www/`. Nginx refusing a config:
`docker compose exec nginx nginx -t` and `docker compose logs -f nginx`. Database
not answering: `docker compose exec mysql mysqladmin ping -h localhost -u root
-partisan7530` or `docker compose exec postgresql pg_isready -U root`. A browser
warning on `https://*.dev.local` means the CA certificate isn't trusted yet.

---

## Host tooling (`install.sh`)

On Debian or Ubuntu, `install.sh` installs host PHP versions with a switcher,
Composer, WP-CLI, Node through nvm, git, the GitHub CLI and the starship prompt.

```bash
sudo ./install.sh                                # everything; PHP 8.3 default
sudo ./install.sh --versions 8.1 8.2 8.3 --default 8.2
sudo ./install.sh --versions=8.2,8.3,8.4         # comma-separated works too
```

`--no-composer`, `--no-wp`, `--no-node`, `--no-git`, `--no-gh` and
`--no-starship` skip a part; `--node-version 20` pins a Node major instead of the
latest LTS. The component selectors — `--php`, `--composer`, `--wp`, `--node`,
`--git`, `--gh`, `--starship` — install **only** what they name and reinstall
something already present, which is how you refresh one tool without touching the
rest (a Node-only run does no `apt-get update` at all). PHP versions always need
the `--php` selector, so `--node 8.2` is rejected rather than quietly ignored.

git and the GitHub CLI are the exception to "install it": they go in **only when
missing**, so a run never upgrades or reconfigures the ones already on the box.
`gh` comes from GitHub's own apt repository, since the version Debian and Ubuntu
ship trails upstream by a long way; if that repository can't be reached the
distro package is used instead. Naming `--git` or `--gh` installs regardless.

```bash
sudo ./install.sh --node                # reinstall just Node via nvm
sudo ./install.sh --gh                  # (re)install the GitHub CLI on its own
sudo ./install.sh --starship            # reinstall the prompt and reset its config
sudo ./install.sh --php 8.2 8.3         # add these PHP versions
```

The same selectors work after `--uninstall`; `--php` without versions removes
every PHP version the script can find, removing Node also removes nvm and its
Node versions for the invoking user, removing `gh` takes its apt repository and
key with it, and a bare `sudo ./install.sh --uninstall` takes out everything it
manages, `phpsw` included. git is the one thing it won't remove — `git.sh`, the
worktree helpers and the agent workflow all run on it, and apt would pull its
dependents out too, so `--uninstall --git` says so and leaves it alone.
Afterwards `phpsw` lists the installed host versions and `sudo phpsw 8.2`
switches the CLI and FPM default.

**The Claude Code CLI, its MCP servers and its plugins are not installed here.**
They live in the `llm-infrastructure` repo alongside the agent workflow — run its
own `install.sh`, which needs no root because everything it installs goes into a
home directory.

---

## Shell helpers (`git.sh`)

`git.sh` is the one file a shell sources: git shortcuts, the prompt, and the
worktree helpers below. `install.sh` writes it into `~/.bashrc`:

```bash
source /path/to/infra/git.sh
```

### The prompt

Current directory and branch, in every terminal — including the ones an agent
runs in, because they inherit the same `~/.bashrc`.

```
jundell@host:~/devops/infra (master*+)$
```

`install.sh` installs [starship](https://starship.rs) into `/usr/local/bin`, so
every user on the box gets the same prompt and a root shell renders like the
rest, and writes the config to `~/.config/starship.toml` for the user who ran
sudo. `git.sh` runs `starship init bash` when the binary is on `PATH` and falls
back to its own `PS1` — same directory, same branch, same status letters — when
it isn't, so neither half depends on the other. A config you have edited is left
alone on later runs; `--starship` resets it, and `--uninstall --starship` removes
only a config still carrying the generated marker line.

The status letters after the branch are `*` unstaged, `+` staged, `?` untracked,
`!` conflicts, `x` deleted, `^`/`v` ahead/behind. A clean tree shows the branch
alone.

### Reload on change

A shell sources `git.sh` once at startup and then runs what it read for as long
as it stays open, so editing an alias reaches every terminal opened afterwards
and none of the ones already running. `git.sh` closes that gap itself: it
compares its own stamp before each prompt (`PROMPT_COMMAND`) and re-sources when
the checkout has changed, so the shell you are standing in is current on the next
prompt.

```bash
infra-git-reload           # this shell, now
infra-git-reload --all     # ... and bump the stamp so every other one follows
```

The stamp is sub-second (`stat %.9Y` / `%Fm`, falling back to `ls -l`) because
whole seconds are not enough: two edits in the same second read as one stamp, and
since the stamp only refreshes on reload, an edit landing in the same second as
the last one compares equal *forever* — missed permanently, not just until the
next prompt.

`llm.sh` in `llm-infrastructure` does the same for itself. Neither file loads the
other, so each watches its own and the names are kept apart — `infra-reload` is
llm.sh's, and defining it here too would just shadow whichever loaded first.

Two ordering details that are easy to get wrong. The hook is appended *after*
`starship init`: starship moves any existing `PROMPT_COMMAND` into
`STARSHIP_PROMPT_COMMAND` and runs it from inside its own precmd, so a hook added
first would end up there and the duplicate check would add a second copy. And
every hook in the chain hands `$?` back untouched — whatever runs before
`starship_precmd` sets the status starship reads to colour the last character, so
a hook that returned 0 of its own would mean the prompt never shows a failure.
Re-sourcing either file is idempotent.

One limit worth knowing: a terminal opened *before* this hook existed doesn't
have it, so it can't reload itself. Those need one `infra-git-reload`, or a new
terminal, to adopt it — after that they stay current on their own.

### Worktrees

`gwtadd` prepares a new worktree and `gwtrm` tears one down, so a branch can be
checked out beside the main repo instead of on top of it.

**A branch `gwtadd` creates is pushed to `origin` with `-u`**, because without an
upstream teammates and CI can't see it and `gwtrm` has no remote branch to delete.
Only a branch it actually created is pushed, and `--no-push` keeps it local. If
the push fails — no network, no write access, a server-side hook — the worktree is
still there and ready; `gwtadd` says the branch is local only and prints the retry
command rather than pretending the whole thing failed. Untracked env files
(`.env`, `.env.local`) are copied over from the main checkout, since a worktree
checkout never brings them along.

```bash
gwtadd feature/login                 # branch off origin's default, push it
gwtadd feature/login master ../login # explicit base and path
gwtadd spike/idea --no-push          # local only
```

`gwtrm <branch>` tears one down: docker containers, volumes, images and networks
for that compose project, the worktree directory, the local branch and the branch
on `origin`. Existence on the remote is checked with `git ls-remote` rather than
the local tracking ref, so a branch pushed but never fetched back still gets
deleted and a stale `origin/<branch>` ref is dropped afterwards. Files a container
wrote as root are removed with `sudo` when a plain `rm -rf` can't touch them — and
if even that fails, `gwtrm` says which path is left and exits non-zero instead of
reporting a cleanup that didn't happen. `--keep-branch`, `--keep-remote` and
`--no-docker` opt out of each part; `-f` discards a dirty worktree and `-y` skips
the confirmation.

### Environments

Linux, macOS and Windows via WSL. Every script is pinned to `#!/bin/bash`, which
exists on all three — and because that is bash 3.2 on macOS, nothing here uses
bash 4 syntax or steps outside a stock BSD userland (no `md5sum`, no
argument-less `mktemp`, no GNU-only flags). `.gitattributes` forces LF endings so
a Windows checkout can't hand a script a `\r` in the shebang. Only `git` and the
usual POSIX text tools are required; `docker` is needed for the stack and the
worktree teardown, and `gh` is optional.
