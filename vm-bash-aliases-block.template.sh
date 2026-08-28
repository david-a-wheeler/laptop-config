# Installed into ~/.bash_aliases (see install_managed_block in common.sh),
# so everything below (noclaude(), heroku_session(), LAPTOP_CONFIG_AUTH_SESSION)
# is only available from bash. A shell that doesn't source ~/.bash_aliases
# (zsh's default config doesn't) won't see any of this. Supporting another
# shell means a separate per-shell file with that shell's own syntax (e.g.
# "local" and the "${*:-...}"/"${@:-...}" forms here aren't portable to
# every shell), not just installing this same file somewhere else. Not
# done, since bash is the only shell in use on these VMs today.

export VISUAL="vim"
export EDITOR="vim"

# Claude Code's native installer puts the binary here.
export PATH="$PATH:$HOME/.local/bin"

# Human interactive shells get a session handle; noclaude() below strips
# it so the sandboxed AI agent can never request host secrets (see
# vm-git-helper.template.py and secrets_server.template.py for the other
# half of that). It also strips SSH_AUTH_SOCK, a separate precaution so the
# agent can't use a forwarded ssh-agent for anything else either, and
# HEROKU_API_KEY, in case a heroku_session (below) subshell is still live in
# this same shell tree when noclaude() gets called: a cached Heroku key
# should never reach the sandboxed agent either.
if [ -z "$LAPTOP_CONFIG_AUTH_SESSION" ]; then
    # shellcheck disable=SC2155  # head/xxd failing here just means an
    # empty or malformed session id, which the secrets server already
    # denies cleanly as "missing session" - not worth splitting the
    # declare/assign for.
    export LAPTOP_CONFIG_AUTH_SESSION="session_$(head -c 16 /dev/urandom | xxd -p)"
fi

noclaude() {
    # shellcheck disable=SC1007  # deliberate: clears all three vars for
    # this one invocation, standard "VAR= VAR= command" idiom, not a
    # typo'd assignment.
    LAPTOP_CONFIG_AUTH_SESSION= SSH_AUTH_SOCK= HEROKU_API_KEY= nono run --allow . --allow ~/.claude @@NONO_EXTRA_READ_ARGS@@ -- claude "$@"
}

# Fetches the Heroku API key once (one approval dialog) and runs
# "command..." (default: an interactive $SHELL) as a *child* process with
# HEROKU_API_KEY set only in that child's environment; this shell never
# holds the key itself. Meant for a burst of heroku commands: heroku_session
# with no args, use heroku normally, exit the subshell, and the key is
# gone from every live process again, with no separate cleanup step and
# nothing to remember to unset.
heroku_session() {
    local key
    # "secrets-client.py" (bare name, not a relative path) is found via
    # $PATH regardless of the current directory: vm-setup.sh installs it
    # to /usr/local/bin, which is on every login shell's $PATH by default
    # on Ubuntu, the same as vm-git-helper.py alongside it.
    key="$(secrets-client.py get heroku-api-key --context "heroku_session: ${*:-interactive shell}")" || return 1
    HEROKU_API_KEY="$key" "${@:-$SHELL}"
}
