# **Secure Local AI Architecture on macOS with Linux guests**

## **1\. Overview and Rationale**

I want to run AI systems while countering security risks. Here’s my basic approach. As the industry learns more, I’m sure there will be better ways long-term, but I want to have a reasonable approach given the limited information currently available. I’ve documented my approach in case others want to use it as a starting point.

Security goals: I want to ensure the AI (both harnesses & any local inference engine) can’t gain access to my personal credentials, arbitrarily read personal files, or push to repos like GitHub. Generally the AI should be able to get/read external data and approved repo data, manipulate local files, run local Linux commands within a VM, and present proposals that I can then choose to review and/or push.

I’ll run Ubuntu Linux Virtual Machines (VMs) that run AI harnesses contained by nono. The harnesses then call out to both local & remote AI inference engines. The Linux VMs will be hosted on MacOS (Macs have a unified memory which is helpful for running local models). Note:

> * **Execution Layer (Ubuntu VMs via UTM):** All AI tools, scripts, and network activities run inside isolated Ubuntu Linux virtual machines. Separate VMs isolate blast radiuses.  
> * **Inference Layer (macOS host \_infer user):** Local inference engines (such as llama.cpp or Stable Diffusion runtimes) run natively on macOS to access Metal GPU acceleration. The local inference process runs under a separate unprivileged macOS account named \_infer and the normal user’s home directory is intentionally NOT accessible by \_infer. This prevents the inference engine from accessing primary user files or keys.  
> * **Credential Isolation:** VMs store no passwords or private SSH keys. Git reads use read-only Personal Access Tokens (PATs) if needed at all. Git writes require host-side SSH agent forwarding backed by hardware security keys (YubiKey ed25519-sk).  
> * **Local Attack Containment and Egress Control:** The VM kernel restricts privilege escalation via PR\_SET\_NO\_NEW\_PRIVS. Outbound network traffic is limited by nftables to DNS, SSH, and HTTP/HTTPS, permitting local security testing against loopback without exposing external networks to arbitrary attack traffic. The AIs are further limited inside the VM by nono and can only get access to “current directory and down” (never its home directory). The printer (CUPS) access by network is disabled; only Unix socket is permitted, which nono easily prevents.

## **2\. Security Controls Summary**

| Component | Implementation | Security Function   |
| :---- | :---- | :---- |
| Host Filesystem | chmod go-rwx /Users/$USER | Blocks the AI inference code (running in the \_infer user account) from reading primary host user data. |
| Shared Storage | /Users/Shared | Permits controlled file exchange outside home directories. |
| Code Egress | Read-only PAT \+ YubiKey SSH Agent | Forces human physical interaction (key tap) for code pushes. |
| VM Sandboxing | nono run \--allow . | Enforces kernel-level Landlock limits to $PWD and disables sudo via PR\_SET\_NO\_NEW\_PRIVS. |
| Network Egress | nftables ruleset | Restricts outbound traffic to ports 22, 53, 80, and 443 while permitting local loopback attacks. |
| Print Isolation | CUPS bound to /run/cups/cups.sock | Permits human printing via D-Bus/libcups while nono blocks AI access to the socket file. |
| Network Exposure | SSH Reverse Tunnel (RemoteForward) | Keeps inference ports bound to 127.0.0.1, avoiding LAN exposure. |

## **3\. Implementation Steps**

### **Phase 1: Hardening the macOS Host**

macOS grants the staff group read access to home directories by default. Run the following on MacOS terminal to revoke these permissions:

chmod go-rwx "$HOME"

### **Phase 2: Preparing the Host AI User**

We will provision the host user account now so it is available later. MacOS background services and daemons’ accounts usually begin with a leading underscore.

> 1. Open macOS System Settings.  
> 2. In “User and Group Accounts” use “Add User” create a (non-administrator) standard macOS user named \_infer.

I chose this name because this user account is for inferencing. Other components also apply AI (e.g., run AI harnesses), so “\_ai” would be misleading.

### 

### **Phase 3: Provisioning VM Discovery and Services**

Inside each Ubuntu VM, install OpenSSH, Avahi, CUPS, curl and nftables (avahi-daemon makes your VM names visible to the host and is thus handy):

\# If you haven’t set the hostname: sudo hostnamectl set-hostname YOUR\_VM\_NAME

sudo apt update && sudo apt install \-y openssh-server avahi-daemon nftables curl cups  
sudo systemctl enable \--now ssh avahi-daemon nftables cups  
sudo systemctl restart avahi-daemon

### **Phase 6: Installing AI Harnesses for Remote Access (Claude and Goose)**

Inside the Ubuntu VM, install the local agent harnesses. These processes act as the localized "hands" for remote AI brains like Anthropic's Claude or Google's Gemini.

> 1. Install Node.js (required for Claude Code) \[there are other ways to install newer nodejs if you prefer that\]:

sudo apt install \-y nodejs npm

> 2. Install Claude Code globally:

sudo npm install \-g @anthropic-ai/claude-code

### **Phase 7: Hardening Local CUPS Printing**

Modify /etc/cups/cupsd.conf in the VM to remove TCP port listeners and enforce UNIX socket binding. This allows human printing while enabling nono to block AI access automatically (nono can easily block access to specific files but has limited control over network access):

sudo sed \-i '/^ \*Listen localhost:631/s/^/\#/' /etc/cups/cupsd.conf  
sudo systemctl restart cups

### **Phase 10: Nono**

Install nono (this reduces the privileges given to the AI even further):  
https://nono.sh/docs/cli/getting\_started/installation

Add functions to \~/.bash\_aliases inside the VM to strip the SSH agent variable and restrict execution to the current working directory and config directory. Here it is for Claude:

cat \<\< 'EOF' \>\> \~/.bash\_aliases  
noclaude() {  
    SSH\_AUTH\_SOCK= nono run \--allow . \--allow \~/.claude \--read \~/.rbenv \-- claude "$@"  
}  
EOF

Unless you set up the API key, you’ll probably want to log in. cd to some directory you want to allow claude to use. Login using just “clause” (without nono) first to get access to subscription OAuth. This allows claude to invoke a web browser to do the logging in and eventually write credentials to \~/.claude/.credentials.json.

Now “cd” to whatever directory you want to use claude in, and run “noclaude” to invoke its nono wrapper. The nono wrapper enforces Landlock kernel limits to $PWD and applies PR\_SET\_NO\_NEW\_PRIVS. This blocks privilege escalation via sudo, prevents directory traversal, and blocks access to /run/cups/cups.sock (so the agent can’t directly print nor attack the printer driver system).

### **Phase 8: Love vim?**

If you like vim, run these in the Linux terminal:

cat \<\< 'EOF' \>\> \~/.bash\_aliases  
export VISUAL="vim"  
export EDITOR="vim"  
EOF

### **Phase 11: Set Host so it runs long periods**

Configure so you can leave the system on for long periods of time.

On the MacOS System Settings Battery-\>Options, Enable “Prevent automatic sleeping on power adapter when the display is off”

Also, on Battery:

*  “Charging” click on the circled “i” &  ensure that “Optimized Battery Charging” is enabled (if it’s plugged in for a long time it’ll limit charging to 80% to reduce battery wear).  
* On Battery \-\> Energy Mode \-\> On power adapter, switch to "High power"

Be sure to keep the case open, and if practical, keep the back of the laptop raised, so that air can freely flow through the system to keep it cool.

Disable Auto-Reboots: Go to System Settings \> General \> Software Update, click the (i) info icon next to Automatic Updates, and toggle off "Install macOS updates". You \*do\* need to install updates, the goal is to not reboot while doing work.

# **MAYBE:**

### **Phase 3: SSH Key Setup on macOS**

Generate a hardware-backed SSH key using a YubiKey on the macOS host (primary user):

ssh-keygen \-t ed25519-sk \-O touch-required \-f \~/.ssh/id\_ed25519\_sk

### **Phase 5: Establishing SSH Access and Reverse Tunneling**

> 1. Add \~/.ssh/id\_ed25519\_sk.pub to GitHub and copy it to the VM from macOS:

ssh-copy-id \-i \~/.ssh/id\_ed25519\_sk.pub YOUR\_VM\_USER@ubuntu-work.local

> 2. Configure \~/.ssh/config on macOS to forward the SSH agent and establish an encrypted reverse tunnel for LLM/inference traffic. (This tunnel guarantees you are ready to use the \_infer host inference engine in the future):

Host ubuntu-work  
    HostName ubuntu-work.local  
    User YOUR\_VM\_USER  
    ForwardAgent yes  
    IdentityFile \~/.ssh/id\_ed25519\_sk  
    RemoteForward 11434 127.0.0.1:11434

### **Phase 9: Configuring Git Split Authentication**

Inside the Ubuntu VM, configure Git to pull via HTTPS (using a read-only PAT) and force all push operations to use SSH:

git config \--global url."git@github.com:".pushInsteadOf "https://github.com/"

### **Phase 8: Configuring Network Egress Rules (nftables)**

Configure /etc/nftables.conf to allow full loopback access (permitting local vulnerability testing) and restrict outbound external connections strictly to DNS (53), SSH (22), and Web traffic (80, 443):

cat \<\< 'EOF' | sudo tee /etc/nftables.conf  
\#\!/usr/sbin/nft \-f

flush ruleset

table inet filter {  
    chain input {  
        type filter hook input priority 0; policy accept;  
    }

    chain forward {  
        type filter hook forward priority 0; policy drop;  
    }

    chain output {  
        type filter hook output priority 0; policy drop;

        \# Allow loopback traffic for local testing and SSH reverse tunnel  
        oif "lo" accept

        \# Allow outbound DNS  
        udp dport 53 accept  
        tcp dport 53 accept

        \# Allow outbound SSH (22) and Web (80, 443\)  
        tcp dport { 22, 80, 443 } accept

        \# Reject all other outbound traffic  
        reject  
    }  
}  
EOF

sudo nft \-f /etc/nftables.conf

### **Phase 11B**

> 3. ??? Ensure API keys are injected securely into your environment via your shell profile (\~/.bashrc or \~/.zshrc). For Goose or alternative harnesses requiring Gemini, set the corresponding variable:

export ANTHROPIC\_API\_KEY="your-anthropic-key"  
export GEMINI\_API\_KEY="your-gemini-key"
