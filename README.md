# laptop-config

Idempotent setup for my macOS host + Ubuntu VM (UTM) setup for running AI
coding agents safely. See [architecture.md](architecture.md) for the why.

## Usage

This repo is meant to be a git checkout on the host and on every VM. To
bring a machine's config up to date with what's checked in:

```
git pull
./host-setup.sh   # on the macOS host
./vm-setup.sh     # on each Ubuntu VM (lftux, mytux, ...)
```

Both scripts are safe to re-run any time - they converge the machine to
match `config.sh`, never accumulate changes. Neither touches secrets.
Re-running after any change (a new VM, an edited `config.sh`, a rotated
secret) is always just "repeat the relevant steps below" - nothing here is
destructive or accumulates state.

### First-time setup (order matters)

A few pieces depend on each other, so the first pass needs this order:

1. **On each VM**: `git pull && ./vm-setup.sh`. Installs `qemu-guest-agent`
   (step 2 needs it) and wires up the git credential helper - `git
   push`/`fetch` won't actually succeed yet, since the host proxy has no
   secret to give out until step 3.
2. **On the host**: `./host-setup.sh`. Starts the git-auth proxy, generates
   the host's SSH key, builds `~/.ssh/config` from `utmctl` (now that
   qemu-guest-agent is running from step 1), and pushes the key straight to
   each VM with `ssh-copy-id` - it'll ask for that VM's login password once
   per VM; after that, key auth just works. No commit, no second VM pass.
3. **On the host**: `./host-secrets.sh set git-host-github-pat`. Without
   this, every `git push`/`fetch` from a VM gets denied (no secret in
   Keychain to release).

After that: `ssh lftux`/`scp x lftux:` works from the host, and a human
shell's `git push`/`git fetch` on a VM triggers a macOS approval dialog and
succeeds; the same command run via `noclaude` fails immediately instead
(see architecture.md's Git Authentication Bridge section).

Adding a new VM later: create it in UTM, then just repeat step 1 (on the
new VM) and step 2 (on the host) - no `config.sh` edits, no commits needed,
and steps you've already done for other VMs (like the Keychain secret in
step 3) already cover it.

**If `ssh <vmname>` still doesn't work** after all of the above: `utmctl
ip-address` depends on UTM's QEMU Guest Agent channel being enabled for
that VM (usually on by default for UTM-created VMs) - check the VM's
Settings > QEMU in UTM if it's not showing up in `~/.ssh/config`. If
`ssh-copy-id` failed for a VM (host-setup.sh prints a warning naming it),
re-run `./host-setup.sh` once the VM's actually reachable.

## Files

- `config.sh` - person/machine-specific values (name, email, ports, ...).
  Reusing this repo for your own setup? Rather than editing this tracked
  file, copy `config.local.sh.example` to `config.local.sh` (gitignored)
  and set overrides there - `config.sh` sources it last, so anything set
  there wins, and your `git pull`s of this repo stay clean.
- `common.sh` - shared shell functions (`host-setup.sh`/`vm-setup.sh` source
  it): template rendering, idempotent block-insertion into dotfiles, git
  config niceties, and a "don't clobber a locally-edited file" install helper.
- `host-setup.sh` - macOS host setup.
- `git_host_proxy.py`, `com.user.githostproxy.template.plist` - the host-side
  git-auth proxy (see architecture.md) and its LaunchAgent.
- `host-secrets.sh` - add/rotate the named secrets `git_host_proxy.py` serves.
- `vm-setup.sh` - Ubuntu VM setup.
- `vm-git-helper.template.py` - the VM-side git credential helper that talks
  to `git_host_proxy.py`.
- `nftables.template.conf` - VM egress firewall ruleset.
- `vm-bash-aliases-block.template.sh` - the managed block installed into each
  VM's `~/.bash_aliases` (editor, `GIT_AUTH_SESSION`, the `noclaude()`
  sandboxed-agent wrapper).
- `claude-CLAUDE.md` - global Claude Code instructions, installed to each
  VM's `~/.claude/CLAUDE.md` (Claude Code runs in the VMs, not on the host,
  so this isn't installed by host-setup.sh). If you've edited the installed
  copy directly and it's newer than this file, vm-setup.sh warns instead of
  overwriting it - see the printed command to pull your edit back in here.
A `*.template.*` file gets rendered (placeholders substituted) before
install; anything else is copied or run as-is.
