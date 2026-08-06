# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# agent-server

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
`sudo tail -30 /var/log/squid/access.log` for `TCP_DENIED`.

## Environment facts

- Hetzner Cloud has **no nested virtualization** (`/dev/kvm` absent). Any
  proposal involving Lima, QEMU, or a VM inside the server is a dead end.
- Target box: CX23, 2 vCPU / 4 GB / 40 GB, Ubuntu, sudo user `honza`, SSH key
  only. 4 GB swapfile added by bootstrap; `vm.swappiness=10`.
- Container UID is 1000 and matches `honza`, so bind mounts need no remapping.
- Billing is hourly (€0.011/h) and a **stopped server still bills** — the
  create/destroy ritual is `snapshot.sh save` then `hcloud server delete`.

## Pinned versions

PHP 8.5 (`php:8.5-cli-bookworm`), Composer 2.8, pecl redis 6.2.0, Node 24,
Claude Code 2.1.202, Codex 0.145.0. Bump deliberately; both agent images must
stay on the same PHP version.

## Layout

```
server/     bootstrap.sh, setup-git.sh, agentctl, agent-set-profile,
            squid.conf, domains/          → deployed to ~/agent/ on the box
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
rsync -a agent-server/ honza@<server-ip>:~/agent/      # trailing slash!
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
`agentctl build`, `agentctl claude|codex`, `agentctl deps -- composer install`
(opens registries, then closes them again), `agentctl logs`.

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
After any bump: `agentctl build` (which flips to `build` and back to `work`
around the build itself), then re-snapshot.

## Decisions already made (do not relitigate without new information)

- **Docker, not a VM, on this host** — no nested virt, and the cloud instance
  already provides the kernel boundary.
- **No `userns-remap`** — it breaks `user: "1000:1000"` against bind mounts
  (files appear as `nobody`). The host is the boundary; the container need not
  also be one.
- **`DOCKER-USER`, not a hand-written nftables table** — Docker on this stack
  uses iptables-nft and a separate `inet filter` table fights with its chains.
- **Profiles keyed on squid *port*, not source IP** — carried over from the Lima
  design where all instances shared a guest address; kept because it avoids
  `squid -k reconfigure` on every switch.
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
  `.gitconfig` and `.git-credentials` files must be pre-created as files.
- Unpinned `pecl install redis` can resolve to a version that won't build
  against the pinned PHP — PECL checks compatibility at install, not selection.
- `tmpfs /tmp` must not be `noexec`; composer and npm execute from there.
- `sudo` over non-interactive ssh needs `ssh -t`.
- `rsync -a agent-server/ host:~/agent/` — the trailing slash on the source is
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
- `hcloud-setup.sh` hardcodes the operator's current IP for SSH; re-run when it
  changes.
- No automated restore test for the snapshot workflow.
- Squid runs without TLS interception (CONNECT passthrough), so allowlisting is
  by hostname only — it cannot see paths or block a specific repo on an allowed
  host.
