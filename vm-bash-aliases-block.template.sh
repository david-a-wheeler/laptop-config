export VISUAL="vim"
export EDITOR="vim"

# Claude Code's native installer puts the binary here.
export PATH="$PATH:$HOME/.local/bin"

# Human interactive shells get a session handle; noclaude() below strips
# it so the sandboxed AI agent can never request host git auth (see
# vm-git-helper.template.py and git_host_proxy.py for the other half of
# that). It also strips SSH_AUTH_SOCK, a separate precaution so the agent
# can't use a forwarded ssh-agent for anything else either.
if [ -z "$GIT_AUTH_SESSION" ]; then
    export GIT_AUTH_SESSION="session_$(head -c 16 /dev/urandom | xxd -p)"
fi

noclaude() {
    GIT_AUTH_SESSION= SSH_AUTH_SOCK= nono run --allow . --allow ~/.claude @@NONO_EXTRA_READ_ARGS@@ -- claude "$@"
}
