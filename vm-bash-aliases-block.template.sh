# Installed into ~/.bash_aliases (see install_managed_block in common.sh),
# so everything below (noclaude(), secret_session(), LAPTOP_CONFIG_AUTH_SESSION)
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
# vm-git-helper.template.py and secrets-server.template.py for the other
# half of that). It also strips SSH_AUTH_SOCK, a separate precaution so the
# agent can't use a forwarded ssh-agent for anything else either, and every
# env var a secret_session (below) can inject, in case such a session's
# subshell is still live in this same shell tree when noclaude() gets
# called: a cached secret should never reach the sandboxed agent either.
# Add to this list whenever a new secret_session caller (like gh_session)
# starts using an env var not already named here.
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

# Fetches one named secret once (one approval dialog) and runs
# "command..." (default: an interactive $SHELL) as a *child* process with
# it set, under the given environment variable name, only in that child's
# environment; this shell never holds the secret itself. Meant for a burst
# of commands against whatever that secret authenticates: secret_session
# with no command, use the tool normally, exit the subshell, and the
# secret is gone from every live process again, with no separate cleanup
# step and nothing to remember to unset.
#
# The env var name doubles as the Keychain secret's name (see config.sh's
# GIT_SECRETS comment): naming a secret "GH_TOKEN" rather than some
# separate logical name means secret_session needs no lookup table
# mapping one to the other, and "host-secrets.sh list" output already
# tells you which env var a secret is for.
secret_session() {
    local var="$1"
    shift
    local key
    # "secrets-client.py" (bare name, not a relative path) is found via
    # $PATH regardless of the current directory: vm-setup.sh installs it
    # to /usr/local/bin, which is on every login shell's $PATH by default
    # on Ubuntu, the same as vm-git-helper.py alongside it.
    key="$(secrets-client.py get "$var" --context "secret_session $var: ${*:-interactive shell}")" || return 1
    env "$var=$key" "${@:-$SHELL}"
}

# Thin, memorable names for secret_session's current callers. Add one here
# whenever a new tool needs its own recurring burst-usage alias; anything
# used once-off can just call "secret_session VAR_NAME ..." directly.
heroku_session() {
    secret_session HEROKU_API_KEY "$@"
}

gh_session() {
    secret_session GH_TOKEN "$@"
}
