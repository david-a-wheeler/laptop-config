# Installed into ~/.bash_aliases (see install_managed_block in common.sh),
# so everything below (noclaude(), LAPTOP_CONFIG_AUTH_SESSION) is only
# available from bash: a shell that doesn't source ~/.bash_aliases (zsh's
# default config doesn't) won't see any of this, regardless of whether
# any given line here happens to also be valid dash/POSIX sh. Supporting
# another shell means installing an equivalent for that shell's own
# startup file, not just installing this same file somewhere else. Not
# done, since bash is the only shell in use on these VMs today.
#
# heroku-session, gh-session, and secrets-client (which both are thin
# wrappers over) are plain executable files instead, installed straight
# to /usr/local/bin by vm-setup.sh: any shell can run those without this
# file at all, which is the direction new secret-fetching tools should
# go rather than adding another bash function here.

export VISUAL="vim"
export EDITOR="vim"

# Claude Code's native installer puts the binary here.
export PATH="$PATH:$HOME/.local/bin"

# Human interactive shells get a session handle; noclaude() below strips
# it so the sandboxed AI agent can never request host secrets (see
# vm-git-helper and secrets-server.template.py for the other half of
# that). It also strips SSH_AUTH_SOCK, a separate precaution so the
# agent can't use a forwarded ssh-agent for anything else either, and every
# env var heroku-session/gh-session can inject, in case such a session's
# child shell is still live in this same shell tree when noclaude() gets
# called: a cached secret should never reach the sandboxed agent either.
# Add to this list whenever a new such tool starts using an env var not
# already named here.
if [ -z "$LAPTOP_CONFIG_AUTH_SESSION" ]; then
    # shellcheck disable=SC2155  # head/xxd failing here just means an
    # empty or malformed session id, which the secrets server already
    # denies cleanly as "missing session" - not worth splitting the
    # declare/assign for.
    export LAPTOP_CONFIG_AUTH_SESSION="session_$(head -c 16 /dev/urandom | xxd -p)"
fi

noclaude() {
    # shellcheck disable=SC1007  # deliberate: clears every var for this
    # one invocation, standard "VAR= VAR= command" idiom, not a typo'd
    # assignment.
    LAPTOP_CONFIG_AUTH_SESSION= SSH_AUTH_SOCK= HEROKU_API_KEY= GH_TOKEN= GITHUB_TOKEN= nono run --allow . --allow ~/.claude @@NONO_EXTRA_READ_ARGS@@ -- claude "$@"
}
