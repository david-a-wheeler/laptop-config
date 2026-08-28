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
   push`/`fetch` won't actually succeed yet, since the secrets server has
   no secret to give out until step 3.
2. **On the host**: `./host-setup.sh`. Starts the secrets server, generates
   the host's SSH key, builds `~/.ssh/config` from `utmctl` (now that
   qemu-guest-agent is running from step 1), and pushes the key straight to
   each VM with `ssh-copy-id` - it'll ask for that VM's login password once
   per VM; after that, key auth just works. No commit, no second VM pass.
3. **On the host**: `./host-secrets.sh set github-pat`. Without
   this, every `git push`/`fetch` from a VM gets denied (no secret in
   Keychain to release).

After that: `ssh lftux`/`scp x lftux:` works from the host, and a human
shell's `git push`/`git fetch` on a VM triggers a macOS approval dialog and
succeeds; the same command run via `noclaude` fails immediately instead
(see architecture.md's Secrets Server section).

Want Heroku access from a VM too? `./rotate-heroku-key.sh` (set
`config.sh`'s `HEROKU_API_KEY_VM` first to lock it to one VM), then
`heroku_session` on the VM - see architecture.md's Secrets Server section.
Optional, and independent of the git setup above.

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

## Network egress is restricted

VMs can only reach a handful of outbound ports by default: SSH (22),
HTTP/HTTPS (80/443), DNS, and the host secrets server - see `config.sh`'s
`NFTABLES_ALLOWED_TCP_PORTS`. This is deliberate (see architecture.md's
Security Controls Summary), not a bug - if something inside a VM can't
reach the network and you're not sure why, this is the first thing to
check. Add the port to `NFTABLES_ALLOWED_TCP_PORTS` in `config.sh` and
re-run `vm-setup.sh`, rather than disabling nftables to work around it.

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
- `secrets_server.template.py`, `com.user.secretsserver.template.plist` -
  the host-side secrets server (see architecture.md) and its LaunchAgent.
  Serves any secret `host-secrets.sh` has stored under Keychain's
  `KEYCHAIN_PREFIX` (`laptop-config-` by default; see `config.sh`) - that
  prefix is what marks a secret as servable at all, nothing else to
  declare. Logs one JSONL record per request (approved/denied/errored,
  never the secret itself) to `/tmp/secrets_server.log`, flushed
  immediately - `tail -f` it while diagnosing.
- `host-secrets.sh` - add/rotate/delete the named secrets `secrets_server.py`
  serves. Include `@vm-hostname` in a name to lock that secret to one
  specific VM instead of leaving it available to any of them.
- `rotate-github-pat.sh` - creates a new GitHub PAT and stores it under
  `github-pat` in Keychain, without touching `config.sh` or the currently
  active secret - safe to run any time (GitHub PATs expire, so expect at
  least once a year) without risking breaking `git push` mid-rotation. See
  the script's own printed output for how to actually cut over once the
  new token's confirmed stored.
- `rotate-heroku-key.sh` - same idea as `rotate-github-pat.sh`, for
  `heroku-api-key` - set `config.sh`'s `HEROKU_API_KEY_VM` to store it
  locked to one VM instead of available to any of them.
- `vm-setup.sh` - Ubuntu VM setup.
- `vm-git-helper.template.py` - the VM-side git credential helper that talks
  to `secrets_server.py`.
- `secrets-client.template.py` - generic VM-side CLI for fetching any named
  secret from `secrets_server.py` (`secrets-client.py get <name>`) - the
  same protocol `vm-git-helper.py` speaks, without git's credential-helper
  format. `heroku_session` (below) is the first non-git caller.
- `nftables.template.conf` - VM egress firewall ruleset.
- `vm-bash-aliases-block.template.sh` - the managed block installed into each
  VM's `~/.bash_aliases`: editor, `LAPTOP_CONFIG_AUTH_SESSION`, the
  `noclaude()` sandboxed-agent wrapper, and `heroku_session` (fetches
  `heroku-api-key` once and runs a command - or an interactive shell if none
  given - as a child process with `HEROKU_API_KEY` set only there, so a
  burst of `heroku` commands needs one approval click instead of one per
  command, and the key is gone again once you exit). Bash-only for now -
  it's installed into `~/.bash_aliases`, which a shell like zsh doesn't
  source by default; supporting another shell would mean a separate file
  in that shell's own syntax, not just installing this one elsewhere.
- `claude-CLAUDE.md` - global Claude Code instructions, installed to each
  VM's `~/.claude/CLAUDE.md` (Claude Code runs in the VMs, not on the host,
  so this isn't installed by host-setup.sh). If you've edited the installed
  copy directly and it's newer than this file, vm-setup.sh warns instead of
  overwriting it - see the printed command to pull your edit back in here.
A `*.template.*` file gets rendered (placeholders substituted) before
install; anything else is copied or run as-is.
