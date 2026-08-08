# agent-server — sandboxed coding agents on a Hetzner Cloud box

> Working on this repo with an agent? Read `CLAUDE.md` first — it carries the
> invariants, the decisions already settled, and the traps already hit.

## What this is

A disposable Hetzner Cloud server that runs Claude Code and Codex CLI against
PHP projects, with the agents' network access enforced from outside the
container they run in.

The agents run with `--dangerously-skip-permissions` and
`--dangerously-bypass-approvals-and-sandbox`. Nobody approves individual
commands. **The network is the control surface instead**: an agent that can
reach `api.anthropic.com` and nothing else has nowhere to send your source and
nothing hostile to pull in, so what it runs inside the box matters far less.

Three nested boundaries, each enforced further out than the thing it contains:

```
Hetzner Cloud Firewall     outside the server — root on the box cannot touch it
  └─ Ubuntu host           squid allowlist + iptables
      └─ container         no route out except squid; agent runs here
```

Containers get no DNS and no route to the internet. Everything goes through a
squid allowlist on the host, and which squid port is reachable *is* the current
profile — one command swaps an agent between "registries open" and "model API
only". Nothing from your laptop is mounted: repos are cloned on the server, and
results leave by `git push`.

The repo provides a `php-toolchain` image (PHP 8.5, Composer, Node 24) with thin
Claude Code and Codex children, `agentctl` for day-to-day control, and a
snapshot workflow that keeps the whole box cheap to destroy and rebuild.

## Install — 7 steps plus prerequisites

Steps 0-3 and 7 run on your laptop, 4-6 on the server. Do them in this order:
the perimeter goes up *before* anything starts listening.

### 0. Prerequisites (laptop)

```bash
brew install hcloud                  # or apt
hcloud context create agent          # paste an API token from the Hetzner console
```

Needed however the server was made: steps 2 and 7 both drive the CLI.

### 1. Create the server (laptop) — skip if you made it in the web console

```bash
hcloud server create --name <server-name> --type cx23 \
  --image ubuntu-24.04 --ssh-key <your-key-name> --location <fsn1|nbg1|hel1>
```

The only unscripted step. Adjust image and location to taste; the type matters
(CX23 = 2 vCPU / 4 GB / 40 GB). Recreating from a snapshot instead? Use
`--image <snapshot-id>` and skip to step 7.

Creating it in the console is fine — but note that a console-created server has
**no Cloud Firewall attached**, so step 2 is doing real work, not repeating
something the console already did.

### 2. Lock the perimeter (laptop) — do this before step 4

```bash
bash laptop/hcloud-setup.sh <server-name>
```

SSH from your IP only; outbound limited to 80/443/53. **This must precede
`bootstrap.sh`**, which starts squid: a proxy listening on a public interface
with no firewall in front of it gets found by scanners within minutes. Re-run
whenever your home IP changes.

### 3. Copy this tree to the server (laptop)

```bash
rsync -a agent-server/ honza@<server-ip>:~/agent/
```

The **trailing slash on the source matters**: it copies the *contents* of
`agent-server/`, so you get `~/agent/server/`, `~/agent/image/`,
`~/agent/laptop/`. Without it you would get `~/agent/agent-server/server/`.
Check with `ssh honza@<server-ip> ls ~/agent`.

### 4. Bootstrap (server)

```bash
ssh -t honza@<server-ip> 'cd ~/agent/server && sudo bash bootstrap.sh'
```

`-t` allocates a TTY so `sudo` can prompt for your password. Afterwards log in
again (a fresh session) so the `docker` group membership applies.

Installs Docker, squid, 4 GB swap, the profile switcher, and the directory
layout. Idempotent — this is also the repair path, so re-run it rather than
patching files on the box.

### 5. Git identity and credentials (server)

```bash
cd ~/agent/server && bash setup-git.sh
```

Prompts for name, email, forge username and a **fine-grained PAT**, writes
`~/agent/coder/.git-credentials` at 0600, and optionally clones your repo into
`~/agent/project_workspace/`.

Scope the PAT to the specific repositories, Contents: read and write, nothing
else. The agent can read this file — it has to, in order to push. Tight scoping
is the control, not secrecy.

### 6. Build images and log in (server)

```bash
agentctl net build      # doctor needs the registries reachable
agentctl doctor         # proves the proxy path, ~30s — run before any long build
agentctl net work
agentctl build          # ~12 min once for php-toolchain, then ~1 min each
                        # opens `build` itself and restores your profile after

agentctl claude         # log in, then /exit
agentctl codex          # log in, then exit
```

Then confirm the network model is actually in force:

```bash
agentctl status                                   # profile : work
sudo iptables -S INPUT | grep -E '312[89]|3130'   # one ACCEPT, one REJECT, one DROP
```

Three rules exactly: `ACCEPT` the profile's port from `172.16.0.0/12`, `REJECT`
all three from `172.16.0.0/12`, `DROP` all three from everywhere else. Stray
single-port `ACCEPT` lines mean an old profile was never closed.

### 7. Snapshot the working state (laptop)

```bash
bash laptop/snapshot.sh save <server-name>
```

That snapshot is your rollback point: images built, both CLIs authenticated.

## Daily use

```bash
ssh honza@<server-ip>
tmux new -s work
agentctl status                       # profile, memory, containers
agentctl logs                         # watch what it reaches for
```

**A container reads its proxy port once, at startup.** Everything below follows
from that: you choose the profile *before* starting a session, and changing it
afterwards does not reach that session — it closes the port the session is
already using, taking its network away rather than widening it.

So pick the session shape by whether the agent installs its own dependencies:

```bash
# It does — attended work. Registries reachable for the whole session.
agentctl net build && agentctl claude
agentctl net work                     # or locked, when you step away

# It doesn't — session stays on `work`, deps run from the host.
agentctl claude                       # second window:
agentctl deps -- composer install     # separate container, same /workspace
```

`agentctl deps` flips to `build`, runs one short-lived container against the
same `../project_workspace` mount, and restores your profile on the way out —
including when the command fails. `vendor/` lands where the session sees it.

It restores the profile you *were* on, not `work`. Start from `build` and it
prints `profile: build` on both sides; that is the restore working, not failing
to close.

The first shape is the convenient one and costs you the supply chain: the agent
can pull anything from packagist and npm until the session ends. Fine while
you're watching it, wrong for anything unattended — `locked` is what earns the
right to skip per-command approval.

Detach with `Ctrl-b d`; the session survives disconnection. Reattach with
`tmux a -t work`.

## Network profiles

| profile | model API | git hosting | registries | use for |
|---------|-----------|-------------|------------|---------|
| `build`   | ✓ | ✓ | ✓ | `agentctl build`, `deps`, attended sessions that install their own deps |
| `work`    | ✓ | ✓ | — | **default** |
| `locked`  | ✓ | — | — | unattended runs, untrusted repos |
| `offline` | — | — | — | executing code you don't trust |

`agentctl net locked` is what earns the right to run agents without approving
each command: reachable destinations are `api.anthropic.com` and nothing else,
so there is nowhere to exfiltrate to and nothing hostile to pull in.

Enforcement has three independent layers, none inside the container:

- `DOCKER-USER -j DROP` — containers can never route out directly, in any
  profile. The only path is squid, reached via the docker bridge gateway. This
  drops port 53 too, so containers have **no DNS**: names are resolved by squid
  on the far side of the proxy. That closes DNS tunnelling as an exfil channel,
  and it means anything in a container that ignores `HTTP_PROXY` simply fails.
- Which squid port is open in `INPUT` from the docker subnet *is* the profile.
  Switching profiles closes the previous port, so repointing `HTTP_PROXY` at
  another one reaches nothing.
- Everything outside `172.16.0.0/12` is refused both in `INPUT` and in
  `squid.conf`. The profile ACLs are keyed on port with no source restriction,
  so without this, anyone who could reach an open port could use the proxy for
  whatever that port allows.

Unsetting `HTTP_PROXY` inside the container therefore achieves nothing.

## Rollback

Two levels:

- **Work in progress**: `git checkout .` / `git clean -fd` in the workspace.
- **The whole box**: `snapshot.sh restore <server> <id>` rebuilds it from your
  image. Everything since is gone — which is the point.

Take a fresh snapshot after each successful `agentctl build`.

**A snapshot captures the active profile.** `agent-set-profile` writes
`/etc/agent/profile` and saves the iptables rules via `netfilter-persistent`,
and `agent-profile.service` re-applies them at boot. A box imaged while on
`build` therefore comes back up on `build` — registries open — every time you
restore it, and every server you create from that image starts the same way.
Set the profile you want to inherit before saving:

```bash
agentctl net work && agentctl status      # profile : work
```

## Cost

Delete the server when you're not using it and recreate from the snapshot:
CX23 bills at €0.011/h, snapshots at €0.0143/GB/month on used space only. Forty
hours a month plus a ~12 GB snapshot is around €0.60.

Note that a *powered-off* server still bills. Delete, don't stop.

## Rules that keep this honest

- Repos are cloned **on the server**. Nothing is bind-mounted from your laptop.
- Results leave via `git push` only.
- The PAT is fine-grained and repo-scoped. Never your main SSH key.
- Keep this box separate from your LAMP droplet. A production host with database
  credentials is exactly where an agent shell should not exist.
- After a suspicious session: `snapshot.sh restore`, then rotate the PAT.
