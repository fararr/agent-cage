# agent-server — agent dev environment on a Hetzner Cloud box

> Working on this repo with an agent? Read `CLAUDE.md` first — it carries the
> invariants, the decisions already settled, and the traps already hit.

## Why there's no Lima here

Hetzner Cloud doesn't expose `/dev/kvm` — no nested virtualization. Lima's QEMU
would fall back to software emulation and be unusably slow.

You don't need it. **The Hetzner instance is the VM.** Their hypervisor gives
you the kernel boundary, and Hetzner Cloud Firewall enforces egress *outside*
the machine entirely — stronger than anything achievable on a laptop, where the
guest could in principle rewrite its own rules.

```
Hetzner Cloud Firewall     outside the server — root on the box cannot touch it
  └─ Ubuntu host           squid allowlist + iptables
      └─ container         no route out except squid; agent runs here
```

## Install — 6 steps

### 1. Copy this tree to the server

```bash
rsync -a agent-server/ honza@<server-ip>:~/agent/
```

The **trailing slash on the source matters**: it copies the *contents* of
`agent-server/`, so you get `~/agent/server/`, `~/agent/image/`,
`~/agent/laptop/`. Without it you would get `~/agent/agent-server/server/`.
Check with `ssh honza@<server-ip> ls ~/agent`.

### 2. Bootstrap (on the server)

```bash
ssh -t honza@<server-ip> 'cd ~/agent/server && sudo bash bootstrap.sh'
```

`-t` allocates a TTY so `sudo` can prompt for your password. Afterwards log in
again (a fresh session) so the `docker` group membership applies.

Installs Docker, squid, 4 GB swap, the profile switcher, and the directory
layout. Idempotent.

### 3. Lock the perimeter (from your laptop)

```bash
brew install hcloud   # or apt
hcloud context create agent      # paste an API token from the Hetzner console
bash laptop/hcloud-setup.sh <server-name>
```

SSH from your IP only; outbound limited to 80/443/53. Re-run when your home IP
changes.

### 4. Git identity and credentials (on the server)

```bash
cd ~/agent/server && bash setup-git.sh
```

Prompts for name, email, forge username and a **fine-grained PAT**, writes
`~/agent/coder/.git-credentials` at 0600, and optionally clones your repo into
`~/agent/project_workspace/`.

Scope the PAT to the specific repositories, Contents: read and write, nothing
else. The agent can read this file — it has to, in order to push. Tight scoping
is the control, not secrecy.

### 5. Build images and log in

```bash
agentctl net build && agentctl doctor    # confirm apt works through squid
agentctl build          # ~12 min once for php-toolchain, then ~1 min each
agentctl claude         # log in, then /exit
agentctl codex          # log in, then exit
```

### 6. Snapshot the working state (from your laptop)

```bash
bash laptop/snapshot.sh save <server-name>
```

That snapshot is your rollback point: images built, both CLIs authenticated.

## Daily use

```bash
ssh honza@<server-ip>
tmux new -s work

agentctl status                       # profile, memory, containers
agentctl deps -- composer install     # registries open, then auto-closed
agentctl claude                       # work
agentctl net locked                   # before leaving it running
agentctl logs                         # watch what it reaches for
```

Detach with `Ctrl-b d`; the session survives disconnection. Reattach with
`tmux a -t work`.

## Network profiles

| profile | model API | git hosting | registries | use for |
|---------|-----------|-------------|------------|---------|
| `build`   | ✓ | ✓ | ✓ | `composer install`, `npm ci` |
| `work`    | ✓ | ✓ | — | **default** |
| `locked`  | ✓ | — | — | unattended runs, untrusted repos |
| `offline` | — | — | — | executing code you don't trust |

`agentctl net locked` is what earns the right to run agents without approving
each command: reachable destinations are `api.anthropic.com` and nothing else,
so there is nowhere to exfiltrate to and nothing hostile to pull in.

Enforcement has two independent layers, neither inside the container:

- `DOCKER-USER -j DROP` — containers can never route out directly, in any
  profile. The only path is squid, reached via the docker bridge gateway. This
  drops port 53 too, so containers have **no DNS**: names are resolved by squid
  on the far side of the proxy. That closes DNS tunnelling as an exfil channel,
  and it means anything in a container that ignores `HTTP_PROXY` simply fails.
- Which squid port is open in `INPUT` from the docker subnet *is* the profile.

Unsetting `HTTP_PROXY` inside the container therefore achieves nothing.

## Rollback

There is no VM snapshot here, so rollback happens at two levels:

- **Work in progress**: `git checkout .` / `git clean -fd` in the workspace.
- **The whole box**: `snapshot.sh restore <server> <id>` rebuilds it from your
  image. Everything since is gone — which is the point.

Take a fresh snapshot after each successful `agentctl build`.

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
