# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# agent-cage

Sandbox for running coding agents (Claude Code, Codex CLI) against PHP projects
on a Hetzner Cloud box, isolated from the operator's laptop and from a separate
production LAMP host.

## Topology

```
Hetzner Cloud Firewall     outside the server; root on the box cannot alter it
  └─ Ubuntu host           squid allowlist + iptables + docker daemon
      └─ container         no route out except squid; the agent runs here
```

The Hetzner instance **is** the VM. There is no hypervisor layer inside it.

## Hard invariants

Do not break these without saying so explicitly:

1. **Containers have no direct route out.** `DOCKER-USER -j DROP` is
   unconditional, in every profile. The only egress is squid on the host,
   reached via the docker bridge gateway (an INPUT-chain path).
2. **Containers have no DNS.** Port 53 is forwarded traffic, so it is dropped.
   Names are resolved by squid on the far side of the proxy. Anything that
   ignores `HTTP_PROXY` fails by design. Do not "fix" this by allowing 53 —
   it closes DNS tunnelling as an exfil channel.
3. **Egress enforcement lives outside the container**, and preferably outside
   the host. Never move a control into the container.
4. **Nothing from the operator's laptop is mounted.** Repos are cloned on the
   server; results leave via `git push` only.
5. **Agents run without command approval** (`--dangerously-skip-permissions`,
   `--dangerously-bypass-approvals-and-sandbox`). The network is the control
   surface, not per-command prompts. Do not reintroduce approval gating as a
   substitute for a network profile.
6. **The production LAMP droplet is off-limits.** No credentials for it, no
   connectivity to it, ever.

## Network profiles

`agentctl net <profile>` → `/usr/local/sbin/agent-set-profile` flips which squid
port is reachable from the docker subnet. That port *is* the profile.

| profile | squid port | model API | git hosting | package registries |
|---------|-----------|-----------|-------------|--------------------|
| build   | 3128 | yes | yes | yes |
| work    | 3129 | yes | yes | no  |
| locked  | 3130 | yes | no  | no  |
| offline | —    | no  | no  | no  |

Default is `work`. `locked` is the one that earns the right to skip approvals.

Allowlists: `server/domains/{model,scm,pkg}.txt`. A build failure that looks like
a network error is usually a missing domain — check
`sudo tail -30 /var/log/squid/access.log` for `TCP_DENIED`. A squid denial
reaches the agent as `HTTP CONNECT failed with status 403`. Editing a domain
file needs `squid -k reconfigure` (or `bootstrap.sh`); only *profile* switches
avoid a reconfigure.

Codex signed in with a **ChatGPT account** talks to `.chatgpt.com`
(`/backend-api/codex/responses`, plus the `codex_apps` MCP connector), not
`api.openai.com` — hence `.chatgpt.com` in `model.txt`. Signing in with an
OpenAI **API key** instead would keep it on `.openai.com` and let that entry go.

Claude Code needs `api.anthropic.com` plus `platform.claude.com` — the latter
handles Console sign-in *and* OAuth token exchange/refresh for claude.ai
accounts, so it is required either way — and `claude.ai` / `claude.com` for
account auth. The rest of its published list is already switched off in
`docker-compose.yml`: `DISABLE_AUTOUPDATER` drops `downloads.claude.ai`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` drops both Datadog intake hosts, and
`ENABLE_CLAUDEAI_MCP_SERVERS=false` drops `mcp-proxy.anthropic.com`. Deliberately
omitted: `code.claude.com`, which only serves docs lookups — expect the
`claude-code-guide` agent and pre-approved WebFetch to fail, nothing else.
Full table: <https://code.claude.com/docs/en/network-config>.

## Environment facts

- Hetzner Cloud has **no nested virtualization** (`/dev/kvm` absent), so any
  proposal that puts a VM inside the server is a dead end.
- Target box: CX23, 2 vCPU / 4 GB / 40 GB, Ubuntu, sudo user `honza`, SSH key
  only. 4 GB swapfile added by bootstrap; `vm.swappiness=10`.
- Container UID is 1000 and matches `honza`, so bind mounts need no remapping.
- Billing is hourly (€0.011/h) and a **stopped server still bills** — the
  create/destroy ritual is `snapshot.sh save` then `hcloud server delete`.

## Pinned versions

PHP 8.5 (`php:8.5-cli-bookworm`), Composer 2.8, pecl redis 6.3.0, Node 24,
Claude Code 2.1.202, Codex 0.145.0. Bump deliberately; both agent images must
stay on the same PHP version.

## Layout

```
server/     secure-init.sh, bootstrap.sh, setup-git.sh, agentctl,
            agent-set-profile, squid.conf, domains/
                                          → deployed to ~/agent/ on the box
image/      php-toolchain/ + claudecode/ + codex/ + docker-compose.yml
laptop/     hcloud-setup.sh, snapshot.sh  → run on the operator's Mac
```

`php-toolchain:8.5` carries PHP, 15 extensions, Composer and Node — a ~12 minute
build. The two agent images are five-line children adding only their CLI, so a
version bump rebuilds in a minute and the PHP versions cannot drift apart.

## Working on this repo

**Nothing here runs in the checkout.** This is a tree of shell scripts, a squid
config and Dockerfiles that only take effect once they are on the box. Editing a
file changes nothing until it is deployed; `bootstrap.sh` *copies*
`squid.conf` and `domains/*.txt` into `/etc/squid/` and installs `agentctl` and
`agent-set-profile` into `/usr/local/{bin,sbin}` — nothing is symlinked, so a
change to any of them needs a redeploy, not just an rsync.

The loop:

```bash
rsync -a agent-cage/ honza@<server-ip>:~/agent/      # trailing slash!
ssh -t honza@<server-ip> 'cd ~/agent/server && sudo bash bootstrap.sh'
ssh honza@<server-ip> 'agentctl doctor'                # ~30s, proves the proxy path
```

There is no test suite and no CI. What you can check before deploying:

```bash
bash -n server/bootstrap.sh server/agentctl server/setup-git.sh laptop/*.sh
sh -n server/agent-set-profile          # /bin/sh, not bash
shellcheck server/* laptop/*.sh         # in the toolchain image
docker compose -f image/docker-compose.yml config -q
sudo squid -k parse                     # on the box only, after deploying
```

Day-to-day on the box: `agentctl status`, `agentctl net <profile>`,
`agentctl build`, `agentctl claude|codex [project]`, `agentctl deps [project] --
composer install` (opens registries, then restores the profile you were on —
which is `build` itself if that is where you already were), `agentctl logs`.

## One session per project

A session sees exactly one project and nothing else. `agentctl claude|codex
<project>` mounts `project_workspace/<project>` — the single directory, not its
parent — at `/workspace/<project>`:

```bash
agentctl claude myshop      # project_workspace/myshop  → /workspace/myshop
agentctl claude             # project_workspace/default_project
```

**The parent `project_workspace` is never mounted.** There is no invocation that
exposes it, so one project's session cannot read or write another's, and a
compromised or confused agent cannot wander sideways. Omitting the name selects
`default_project`, created by `bootstrap.sh`, rather than widening the mount —
that is the whole reason a default project exists.

The path being distinct per project matters a second time over: Claude Code keys
its history and memory on the working directory, so notes taken in one project
stay out of another's context.

Adding a project is `git clone` into `~/agent/project_workspace/<name>`; the
name is then the argument. Sessions are meant to be run one at a time — nothing
stops two, but the network profile is one global setting for the box, the PAT is
one file shared by every session, and the resource limits above assume a single
agent on a CX23.

## Where a profile actually lives

`agent-set-profile` is the only place the four representations of "the current
profile" are kept in step, and they are not interchangeable:

1. `iptables INPUT` — REJECT 3128-3130 from `172.16.0.0/12`, then ACCEPT the one
   port for this profile. This is the enforcement; the rest is plumbing.
2. `/etc/agent/profile` — the string, read back by `agentctl status` and by
   `agent-profile.service` to re-apply the rules after a reboot.
3. `/etc/agent/proxy.env` — `env_file` for `docker compose run`, i.e. runtime.
4. `~honza/.docker/config.json` — BuildKit's proxies, i.e. build time. Missing
   this is the `Temporary failure resolving deb.debian.org` failure above.

Adding or renaming a profile therefore touches four files: `agent-set-profile`
(the port map), `squid.conf` (`http_port` + `acl myportname` + `http_access`),
`agentctl` (usage text), and the tables in this file and `README.md`.

Note that the **docker daemon itself is not proxied**. Image pulls are host
process traffic (OUTPUT chain), so `DOCKER-USER` never sees them and they reach
the internet directly in every profile, `offline` included — only the Hetzner
firewall's 443 rule applies. Squid constrains what runs *in* containers, not
what Docker fetches to build them.

## Changing pinned versions

A PHP bump is not one edit. `docker-compose.yml` carries the version in four
places — the `toolchain` build arg, its `image:` tag, and the `BASE` build arg of
both agent services — and the Dockerfiles carry defaults that must not disagree.
A PHP bump also drags `REDIS_EXT_VERSION`, since PECL extensions compile against
php-src's internal headers and break when those move; check the new PHP's
release notes for removed extensions and relocated headers *before* building.
After any bump: `agentctl build` (which flips to `build` and back to `work`
around the build itself), then re-snapshot.

## Decisions already made (do not relitigate without new information)

- **Docker, not a VM, on this host** — no nested virt, and the cloud instance
  already provides the kernel boundary.
- **No ufw** — `secure-init.sh` defaults it off. ufw reinserts its chains at the
  top of `INPUT` on every reload, above the rules `agent-set-profile` puts at
  position 1, which can cut containers off from squid. Same family of reasoning
  as the nftables decision below: one owner per chain.
- **No `userns-remap`** — it breaks `user: "1000:1000"` against bind mounts
  (files appear as `nobody`). The host is the boundary; the container need not
  also be one.
- **`DOCKER-USER`, not a hand-written nftables table** — Docker on this stack
  uses iptables-nft and a separate `inet filter` table fights with its chains.
- **Profiles keyed on squid *port*, not source IP** — switching profiles is then
  an iptables change, with no `squid -k reconfigure` on every switch. The port
  selects *which* profile;
  it is never the only control. `squid.conf` also denies any source outside
  `172.16.0.0/12`, and `agent-set-profile` drops 3128-3130 from everywhere but
  the docker subnet — otherwise reaching an open port from outside is enough to
  use the proxy, since the profile ACLs carry no source restriction.
- **Fine-grained PAT, mounted read-only at `/home/node/.git-credentials`** — the
  agent can read it because it must push. Tight repo scoping is the control, not
  secrecy. Rotate after any suspicious session.
- **Rollback is coarse**: `git checkout . && git clean -fd` in-session, or
  `snapshot.sh restore` for the whole box. There are no VM snapshots here.

## Gotchas already hit — do not reintroduce

- BuildKit needs proxies in `~/.docker/config.json`; `/etc/agent/proxy.env` only
  covers `docker compose run`. Missing this gives
  `Temporary failure resolving deb.debian.org`.
- PEAR/PECL use PHP streams and ignore `HTTP_PROXY`; `pear config-set http_proxy`
  is required or `pecl install` hangs.
- `docker0` stays on `172.17.x` even with a `default-address-pools` of
  `172.31.0.0/16`. Match `172.16.0.0/12`.
- Docker creates a **directory** for a bind-mount source that doesn't exist. The
  `.gitconfig` and `.git-credentials` files must be pre-created as files. Once it
  has happened the container will not start at all — runc fails with `not a
  directory ... MS_BIND`, because the image has a real `/home/node/.gitconfig`
  and a directory cannot be bound over a file. `bootstrap.sh` repairs this.
- Unpinned `pecl install redis` can resolve to a version that won't build
  against the pinned PHP — PECL checks compatibility at install, not selection.
  A stale *pin* fails the same way: redis 6.2.0 does not build on PHP 8.5, which
  moved `ext/standard/php_smart_string.h` to `Zend/zend_smart_string.h`. 6.3.0
  uses the new path (and still builds on 8.4).
- **Do not put `opcache` in `docker-php-ext-install`.** PHP 8.5 compiles OPcache
  into the binary; it is no longer a shared extension. Installing it configures
  cleanly, builds nothing, and fails late with `cp: cannot stat 'modules/*'`.
  `cp: cannot stat 'modules/*'` from `install-modules` always means *that
  extension produced no `.so`* — the extension is built in or unbuildable, not
  broken. The failing extension is not named in the error: `make -j install`
  runs `install-modules` and `install-headers` concurrently, so rebuild with
  `--progress=plain` and read upwards for the last `checking for X ... no`.
- `tmpfs /tmp` must not be `noexec`; composer and npm execute from there.
- A container's proxy port is fixed when it starts, from `/etc/agent/proxy.env`.
  Switching profiles from another terminal does not reach a session already
  running — it *closes* the port that session is still pointing at. So
  dependency installs run from the **host** via `agentctl deps`, which sets the
  profile first and then starts a fresh container. `composer install` typed
  inside a live `agentctl claude` session cannot reach the registries, and no
  amount of `agentctl net build` from another shell will change that. An agent
  that must install its own dependencies needs the session *started* on build:
  `agentctl net build && agentctl claude <project>`, back to `work` afterwards.
- Changing `DOCKER_NETS` orphans the rules saved under the old value:
  `agent-set-profile` deletes by exact spec, and `netfilter-persistent` reloads
  what it saved. After such a change, check `sudo iptables -S INPUT` for rules
  carrying the previous subnet and delete them by hand.
- The agent containers run with `tty: true`, so git pages by default: `git log`
  inside a session waits on a keypress that never comes. The container
  `.gitconfig` sets `core.pager = cat`, and `core.editor = true` so a `git
  commit` with no `-m` aborts on an empty message rather than hanging in an
  editor nobody can close. Don't remove either while `tty: true` stands.
- The Hetzner firewall allows the host outbound **80/443/53 only**, so git over
  SSH fails from the host: `git@github.com:` times out on port 22. It looks like
  a key problem and is not — check the port first with
  `timeout 8 bash -c '</dev/tcp/github.com/22'`. Either use HTTPS with the PAT,
  or point `~/.ssh/config` at GitHub's 443 endpoint (`HostName ssh.github.com`,
  `Port 443`, `User git`) — verified working; full example in README step 6.
  Containers cannot take the SSH route at all: squid tunnels CONNECT to 443, but
  git-over-SSH would need a `ProxyCommand`.
- The Cloud Firewall's inbound rule is a single IPv4 `/32`. Everything else is
  denied, IPv6 included, so ssh to the server's v6 address times out with the
  same signature as a stale IP. Use the v4 address, or `ssh -4`.
- `sudo` over non-interactive ssh needs `ssh -t`.
- `agentctl` is *copied* to `/usr/local/bin`, but `docker-compose.yml` is read in
  place from `~/agent/image/`. An rsync without `bootstrap.sh` therefore leaves a
  stale `agentctl` driving a current compose file, and since projects became an
  argument that combination fails **silently**: the old branch discards the
  project name, nothing exports `AGENT_WORKDIR`, compose falls back to its
  default, and the session starts in `default_project` with no error at all.
  `grep -c default_project /usr/local/bin/agentctl` is 0 when it is stale.
- `rsync -a agent-cage/ host:~/agent/` — the trailing slash on the source is
  load-bearing.

## Conventions

- Shell scripts: `set -euo pipefail` for bash, `set -e` for the `/bin/sh`
  profile switcher. Syntax-check with `bash -n` / `sh -n` before committing.
- `agent-set-profile` is the only thing in sudoers; keep it that way.
- Prefer editing `server/` in the repo and re-running `bootstrap.sh` (it is
  idempotent) over patching files in place on the box.
- `agentctl doctor` proves the proxy path in ~30s. Run it before any long build.

## Known open items

- No host-side rule pins the *server's* own egress to squid; only containers are
  constrained. The Hetzner Cloud Firewall limits the host to 80/443/53.
- `hcloud-setup.sh` pins the SSH rule to whatever `icanhazip.com` returns at the
  moment it runs, and nothing re-checks it afterwards, so the rule goes stale on
  every change of network. Re-running the script is the whole fix, and it is
  deliberately the *only* thing that writes firewall rules: `replace-rules` is
  all-or-nothing, so a second script re-pointing just SSH would own all four.
  Still open in that nothing warns before the lockout, which presents as ssh
  timing out on port 22 and reads exactly like a broken key.
- No automated restore test for the snapshot workflow.
- Squid runs without TLS interception (CONNECT passthrough), so allowlisting is
  by hostname only — it cannot see paths or block a specific repo on an allowed
  host.
