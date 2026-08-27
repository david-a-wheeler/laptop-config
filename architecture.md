# **Secure Local AI Architecture on macOS with Linux guests**

## **1. Overview and Rationale**

I want to run AI systems while countering security risks. Here's my basic approach. As the industry learns more, I'm sure there will be better ways long-term, but I want to have a reasonable approach given the limited information currently available. I've documented my approach in case others want to use it as a starting point.

Security goals: I want to ensure the AI (both harnesses & any local inference engine) can't gain access to my personal credentials, arbitrarily read personal files, or push to repos like GitHub. Generally the AI should be able to get/read external data and approved repo data, manipulate local files, run local Linux commands within a VM, and present proposals that I can then choose to review and/or push.

I'll run Ubuntu Linux Virtual Machines (VMs) that run AI harnesses contained by nono. The harnesses then call out to both local & remote AI inference engines. The Linux VMs will be hosted on MacOS (Macs have a unified memory which is helpful for running local models). Note:

> * **Execution Layer (Ubuntu VMs via UTM):** All AI tools, scripts, and network activities run inside isolated Ubuntu Linux virtual machines. Separate VMs isolate blast radiuses.
> * **Inference Layer (macOS host \_infer user):** Local inference engines (such as llama.cpp or Stable Diffusion runtimes) run natively on macOS to access Metal GPU acceleration. The local inference process runs under a separate unprivileged macOS account named \_infer and the normal user's home directory is intentionally NOT accessible by \_infer. This prevents the inference engine from accessing primary user files or keys.
> * **Credential Isolation:** VMs store no passwords, private SSH keys, or long-lived tokens. A host-side secrets server (`secrets_server.py`) holds named secrets in macOS Keychain and releases one only after a human clicks "Authorize" on a GUI prompt naming which secret and what operation triggered it. See "Secrets Server" below. (An earlier draft of this required a YubiKey-backed SSH key for pushes; that turned out to be overkill given the human-approval step already in place, so it's dropped.)
> * **Local Attack Containment and Egress Control:** The VM kernel restricts privilege escalation via PR\_SET\_NO\_NEW\_PRIVS. Outbound network traffic is limited by nftables to DNS, SSH, and HTTP/HTTPS, permitting local security testing against loopback without exposing external networks to arbitrary attack traffic. The AIs are further limited inside the VM by nono and can only get access to "current directory and down" (never its home directory). The printer (CUPS) access by network is disabled; only Unix socket is permitted, which nono easily prevents.

## **2. Security Controls Summary**

| Component | Implementation | Security Function   |
| :---- | :---- | :---- |
| Host Filesystem | chmod go-rwx /Users/$USER | Blocks the AI inference code (running in the \_infer user account) from reading primary host user data. |
| Shared Storage | /Users/Shared | Permits controlled file exchange outside home directories. |
| Code Egress | Host Keychain secret + human-approved GUI prompt | VM never holds a token; every git fetch/push needs a per-request click on the host (`secrets_server.py`). |
| VM Sandboxing | nono run \--allow . | Enforces kernel-level Landlock limits to $PWD and disables sudo via PR\_SET\_NO\_NEW\_PRIVS. |
| Network Egress | nftables ruleset | Restricts outbound traffic to ports 22, 53, 80, and 443 while permitting local loopback attacks. |
| Print Isolation | CUPS bound to /run/cups/cups.sock | Permits human printing via D-Bus/libcups while nono blocks AI access to the socket file. |
| Network Exposure | SSH Reverse Tunnel (RemoteForward) | Keeps inference ports bound to 127.0.0.1, avoiding LAN exposure. (Not yet built out - see `ENABLE_INFERENCE_SSH_TUNNEL` in config.sh.) |
| VM Access | Host `~/.ssh/id_ed25519` (plain, no hardware key), pushed to each VM's `authorized_keys` via `ssh-copy-id`; `~/.ssh/config` built from live `utmctl` queries | One-directional human convenience login (`ssh`/`scp` a VM by name); VMs never get host access. Adding a VM needs no host-side config, no commit - `host-setup.sh` re-queries UTM and re-pushes the key every run. |

**Known limitation, accepted rather than solved:** ports 80 and 443 are allowed to *any* destination (general web/package/doc access is a hard requirement, not optional), so a compromised or malicious agent inside a VM can still exfiltrate data or receive C2 instructions over HTTPS to any host it wants - port-based filtering can't tell that apart from legitimate traffic, since both are just TLS on 443. A stronger mitigation would filter by destination instead of port (TLS's SNI field is sent in cleartext, so domain-allowlisting is possible without decrypting traffic), but that's real added complexity - a filtering proxy, plus a domain allowlist to maintain - not implemented here. What the current egress rules *do* buy you: blocking non-web C2/exfiltration channels and lateral movement to arbitrary ports. The things that matter most (git push access, host secrets, the host filesystem) are protected by the other layers in this table, not by egress filtering - that's deliberate, since egress filtering alone can't be made to fully close this gap while still allowing normal web use.

## **3. Secrets Server**

Autonomous AI agents (Claude Code, Goose) inside the VMs need file access and command execution, but storing persistent GitHub PATs, API keys, or private SSH keys inside a VM creates an exfiltration risk. Instead, every such secret lives only on the host, in Keychain, and VMs request one at a time over the network:

```mermaid
flowchart LR
    subgraph VM["Ubuntu Guest VM"]
        Human["Human interactive shell<br/>(GIT_AUTH_SESSION set)"]
        Agent["AI agent wrapper<br/>(noclaude - session stripped)"]
    end

    subgraph Host["macOS Host"]
        Server["Secrets server<br/>secrets_server.py :9876"]
        Dialog["AppleScript dialog<br/>(human approval)"]
        Keychain["macOS Keychain<br/>(laptop-config- prefix)"]
    end

    Human -- "secret request (session id)" --> Server
    Agent -. "blocked: no session id" .-> Server
    Server -- "look up prefixed, optionally VM-locked name" --> Keychain
    Server -- "show approval prompt" --> Dialog
    Dialog -- "Authorize" --> Server
    Server -- "release secret" --> Human
```

| Component | Industry / Enterprise Equivalent | Security Function |
| :---- | :---- | :---- |
| **Secrets Server** (`secrets_server.py`) | AWS IMDSv2 / GCP Metadata Server | Keeps long-lived credentials off the guest OS completely. |
| **VM Credential Helper** (`vm-git-helper.template.py`) | Git Credential Manager / AWS Helper | Intercepts native Git auth requests transparently in memory. |
| **GIT\_AUTH\_SESSION** | OAuth 2.0 / OIDC Session Token | Scopes credential issuance strictly to human shell process trees. |
| **Wrapper Scrubbing** (`noclaude()`) | Container Environment Scrubbing | Prevents AI agents from inheriting authorization handles. |
| **macOS Keychain Storage** | Vault / Secret Manager | Stores secrets encrypted at rest on the host system. |

The server serves any secret `host-secrets.sh` has stored (not just a single GitHub PAT) - `vm-git-helper.template.py` is one caller (resolving which secret to ask for from `config.sh`'s `GIT_SECRETS`), but any VM-side script can ask for a secret by name the same way. Heroku auth is one such case: rather than the `heroku` CLI's own OAuth login (which doesn't work well inside a sandboxed, largely-unattended VM), a Heroku API key is stored like any other secret and requested the same way.

**What marks a secret as servable at all** is purely how it's named in Keychain: `host-secrets.sh` stores everything under `config.sh`'s `KEYCHAIN_PREFIX` (`laptop-config-` by default), and the server only ever looks up prefixed names - a request for anything not stored that way is indistinguishable from "doesn't exist." There's no separate list of allowed secret names anywhere to keep in sync; adding a new servable secret is just `host-secrets.sh set <name>` on the host.

**Locking a secret to one specific VM** (e.g. a Heroku key that should only go to the VM that actually runs a given project) uses the same idea: store it as `<name>@<vm-hostname>` instead of plain `<name>` (`host-secrets.sh set heroku-api-key@mytux`). The server resolves which VM is asking from the request's real network source IP, cross-referenced against `utmctl ip-address` - the same source of truth `host-setup.sh` already uses to build `~/.ssh/config` - and tries the VM-locked name first, falling back to the unlocked name if there isn't one. Locking to more than one VM needs no new syntax: store the secret again under a second `@vm-hostname`. Don't store both a locked and an unlocked copy of the same name unless you actually want every other VM falling through to the unlocked one.

A client can never request a locked name directly - any `secret_name` containing `@` is rejected outright, before any Keychain lookup, since the suffix must only ever come from the server's own IP-based resolution. This closes an otherwise-obvious bypass (a VM asking for `"heroku-api-key@mytux"` directly would otherwise just get it back verbatim via the unlocked-name lookup). This case also triggers its own single-button alert dialog on the host - always denied regardless of the click, since it's not a real authorization decision, but a human should notice: it's either a misconfigured client or a deliberate attempt to name another VM's secret.

**Why one VM can't forge being another VM, and where that guarantee actually ends:** with the direct-request bypass above closed, the only remaining way to get a secret locked to `mytux` is for the server to resolve a request's *real* TCP source IP address as `mytux`'s. Spoofing that would mean a process on `lftux` sending a packet whose source IP lies about which VM it came from - which needs a raw socket (`SOCK_RAW`), and creating one needs the `CAP_NET_RAW` Linux capability. An ordinary unprivileged process doesn't have it (confirmed here: `socket.socket(AF_INET, SOCK_RAW, IPPROTO_TCP)` as the normal non-root user raises `PermissionError: [Errno 1] Operation not permitted`) - so a compromised AI agent (already further restricted by `noclaude()`/nono, which blocks privilege escalation via `PR_SET_NO_NEW_PRIVS`) simply cannot construct a packet with a forged source address in the first place, regardless of anything the secrets server itself does. The kernel fills in the VM's real address on every outbound connection a normal process makes; there's no way to lie about it from userspace without root.

That's the actual scope of the guarantee: **it holds against a compromised or malicious *unprivileged* process inside a VM** (the threat model this whole design defends against - see Section 1), not against an attacker who has already escalated to root inside a guest VM. A root process *can* open raw sockets, and at that point whether a forged packet's replies would actually reach it depends on the isolation properties of UTM's virtual network (Apple's `vmnet.framework` in Shared Network/NAT mode - the mode already established elsewhere in this doc, since mDNS doesn't cross it) - specifically, whether that virtual switch would let one VM ARP-spoof another's address to redirect return traffic. That hasn't been tested here and isn't asserted either way. In practice this isn't a gap worth closing right now: a guest that's already root-compromised is a far larger problem than this one endpoint, and every VM here is already fully controlled by the same person `host-secrets.sh` runs as, so "another VM" was never a meaningfully different trust boundary than "the host operator" to begin with. If that stops being true - e.g. a VM running code from a source you don't fully trust with root - VM-locking by source IP alone stops being sufficient, and would need a real per-VM credential (a token minted once and stored only in that VM, checked in addition to the IP) instead.

Verification: from a human interactive shell, `git push`/`git fetch` should trigger a macOS dialog naming the repo path, commit, and session; from `noclaude`, the same operation should fail immediately with no dialog, since `GIT_AUTH_SESSION` is stripped.

**Testing the server directly:** always set `"dry_run": true` in a `/secret` request rather than sending a real one - the server never reads the secret's actual value out of Keychain in that case (see `keychain_secret_exists()`), so the response can never contain it, no matter how it's displayed. A real `/secret` response legitimately contains the secret in plaintext (that's the whole point, for the caller's benefit) - a raw `curl` against a real request once printed an actual token straight into a terminal.

## **4. Setup**

Everything below "Overview" used to be a list of commands to copy-paste by hand into each VM and the host - which is exactly how it drifted out of sync with what was actually configured. That's now `config.sh` + `common.sh` + `host-setup.sh` + `host-secrets.sh` + `vm-setup.sh`, checked into this repo, idempotent, and safe to re-run after every `git pull`. See [README.md](README.md) for how to run them, and the scripts themselves (they're commented) for what each step does and why.
