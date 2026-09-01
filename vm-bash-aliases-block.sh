# Installed into ~/.bash_aliases (see install_managed_block in common.sh),
# so everything below (LAPTOP_CONFIG_AUTH_SESSION) is only available from
# bash: a shell that doesn't source ~/.bash_aliases (zsh's default config
# doesn't) won't see it, regardless of whether it happens to also be
# valid dash/POSIX sh. Supporting another shell means installing an
# equivalent for that shell's own startup file, not just installing this
# same file somewhere else. Not done, since bash is the only shell in use
# on these VMs today.
#
# noclaude, heroku-session, gh-session, and secrets-client are plain
# executable files instead, installed straight to /usr/local/bin by
# vm-setup.sh: any shell can run those without this file at all, which
# is the direction new tools should go rather than adding a bash
# function here. Not a template either, unlike this file: no
# @@VAR@@ substitution left here once noclaude moved out.

export VISUAL="vim"
export EDITOR="vim"

# Claude Code's native installer puts the binary here.
export PATH="$PATH:$HOME/.local/bin"

# Human interactive shells get a session handle; noclaude strips it so
# the sandboxed AI agent can never request host secrets (see
# vm-git-helper and secrets-server.template.py for the other half of
# that). noclaude also strips SSH_AUTH_SOCK, a separate precaution so the
# agent can't use a forwarded ssh-agent for anything else either, and
# every env var heroku-session/gh-session can inject, in case such a
# session's child shell is still live in this same shell tree when
# noclaude gets called: a cached secret should never reach the sandboxed
# agent either. Add to noclaude's own list whenever a new such tool
# starts using an env var not already named there.
if [ -z "$LAPTOP_CONFIG_AUTH_SESSION" ]; then
    # shellcheck disable=SC2155  # head/xxd failing here just means an
    # empty or malformed session id, which the secrets server already
    # denies cleanly as "missing session" - not worth splitting the
    # declare/assign for.
    export LAPTOP_CONFIG_AUTH_SESSION="session_$(head -c 16 /dev/urandom | xxd -p)"
fi
