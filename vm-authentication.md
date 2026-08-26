# **Ephemeral Git Authentication Bridge for Sandboxed Local AI**

## **1\. Requirements & Security Goals**

When running autonomous AI agents (Claude Code, Goose) inside local Linux virtual machines (VMs), file access and command execution are necessary. However, storing persistent GitHub Personal Access Tokens (PATs) or private SSH keys inside the VM creates exfiltration risks.

My solution is to store the GitHub secret in the host, not in the guest VMs, as follows:

> * **Zero VM Secret Storage:** No persistent GitHub PATs, OAuth tokens, or private SSH keys are stored on the VM disk or in static environment variables.  
> * **Context-Aware Human Authorization:** Every Git authentication attempt requires explicit human approval via a native macOS GUI prompt showing repository path, commit summary, and session ID.  
> * **Process-Scoped Access:** Access is bound exclusively to human interactive terminal sessions using a dynamic session handle (GIT\_AUTH\_SESSION).  
> * **Sandbox Isolation:** AI execution wrappers (such as noclaude or nogoose backed by Landlock/nono) explicitly strip session variables, rendering AI agents incapable of requesting credentials or pushing code.  
> * **Zero Host Configuration Fluff:** Host bridge IP addresses and VM default gateways are resolved dynamically at runtime without manual IP editing or network interface hardcoding.

## **2\. Architecture & Enterprise Alignment**

This pattern translates cloud-native Zero-Trust security primitives to local desktop virtualization.

┌────────────────────────────────────────────────────────┐  
│                      Ubuntu Guest VM                   │  
│  ┌─────────────────────────┐  ┌─────────────────────┐  │  
│  │ Human Interactive Shell │  │   AI Agent Wrapper  │  │  
│  │ (GIT\_AUTH\_SESSION set)  │  │  (Session Stripped) │  │  
│  └────────────┬────────────┘  └──────────┬──────────┘  │  
└───────────────┼──────────────────────────┼─────────────┘  
                │                          │ (Blocked)  
   Git Request  │                          ▼  
   (Port 9876\)  │            ┌───────────────────────────┐  
                └───────────►│  Host Proxy (macOS Bridge)│  
                             └─────────────┬─────────────┘  
                                           │ Prompt User  
                                           ▼  
                             ┌───────────────────────────┐  
                             │ macOS AppleScript Dialog  │  
                             └─────────────┬─────────────┘  
                                           │ Fetch Secret  
                                           ▼  
                             ┌───────────────────────────┐  
                             │     macOS Keychain        │  
                             └───────────────────────────┘

 

| Component | Industry / Enterprise Equivalent | Security Function   |
| :---- | :---- | :---- |
| **Host IP Proxy** | AWS IMDSv2 / GCP Metadata Server | Keeps long-lived root credentials off the guest OS completely. |
| **VM Credential Helper** | Git Credential Manager / AWS Helper | Intercepts native Git auth requests transparently in memory. |
| **GIT\_AUTH\_SESSION** | OAuth 2.0 / OIDC Session Token | Scopes credential issuance strictly to human shell process trees. |
| **Wrapper Scrubbing** | Container Environment Scrubbing | Prevents AI agents from inheriting authorization handles. |
| **macOS Keychain Storage** | Vault / Secret Manager | Stores PAT securely encrypted at rest on the host system. |

## **3\. Implementation Guide**

### **Step 1: macOS Host Setup**

#### **A. Create & Store Secret in Keychain**

Create a GitHub secret token. GitHub Settings \> Developer Settings \> Personal Access Tokens… I chose classic, repo+workflow (so I can update workflows). This will show a one-time “github\_pat\_…” or “ghp\_…” value.

Run this once in your macOS terminal to store your GitHub Personal Access Token encrypted in Keychain:

security add-generic-password \-a "$USER" \-s "git-host-proxy-pat" \-w "github\_pat\_YOUR\_ACTUAL\_TOKEN\_HERE"

OR

security add-generic-password \-a "$USER" \-s "git-host-proxy-pat" \-w "ghp\_YOUR\_CLASSIC\_PAT\_HERE"

NOTE: WHEN IT EXPIRES, SAY IN A YEAR, YOU’LL NEED TO RUN THIS AGAIN.

 

#### **B. Create Host Proxy Script on host system (Mac)**

Create \~/bin:

mkdir \-p \~/bin/

Then create \~/bin/git\_host\_proxy.py on macOS:

\#\!/usr/bin/env python3  
"""macOS Host Git Authorization Proxy Server.

Listens on the virtual bridge interface, queries Keychain, and prompts for  
human approval.  
"""  
import json  
import re  
import socket  
import subprocess  
import sys  
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN\_PORT \= 9876  
KEYCHAIN\_SERVICE\_NAME \= "git-host-proxy-pat"

def get\_virtual\_bridge\_ip() \-\> str:  
  """Scans macOS interfaces for UTM/Virtualization bridge adapters."""  
  try:  
    virtual\_ifaces \= \[  
        name  
        for \_, name in socket.if\_nameindex()  
        if name.startswith(("bridge", "vmnet", "vnic"))  
    \]  
    for iface in virtual\_ifaces:  
      out \= subprocess.check\_output(  
          \["ifconfig", iface\], text=True, stderr=subprocess.DEVNULL  
      )  
      match \= re.search(r"inet\\s+(\\d+\\.\\d+\\.\\d+\\.\\d+)", out)  
      if match:  
        return match.group(1)  
  except Exception:  
    pass  
  return "127.0.0.1"

def get\_token\_from\_keychain() \-\> str:  
  """Retrieves the encrypted GitHub PAT directly from macOS Keychain."""  
  try:  
    return subprocess.check\_output(  
        \[  
            "security",  
            "find-generic-password",  
            "-s",  
            KEYCHAIN\_SERVICE\_NAME,  
            "-w",  
        \],  
        text=True,  
        stderr=subprocess.DEVNULL,  
    ).strip()  
  except subprocess.CalledProcessError:  
    return ""

class AuthProxyHandler(BaseHTTPRequestHandler):

  def do\_POST(self):  
    if self.path \!= "/token":  
      self.send\_response(404)  
      self.end\_headers()  
      return

    content\_length \= int(self.headers.get("Content-Length", 0))  
    body \= self.rfile.read(content\_length)

    try:  
      payload \= json.loads(body.decode("utf-8"))  
    except Exception:  
      self.\_respond({"status": "denied", "reason": "Invalid JSON"}, 400\)  
      return

    session\_id \= payload.get("session", "")  
    repo\_path \= payload.get("path", "Unknown Path")  
    commit\_info \= payload.get("commit", "No commit details")

    if not session\_id:  
      self.\_respond(  
          {"status": "denied", "reason": "Missing GIT\_AUTH\_SESSION"}, 403  
      )  
      return

    token \= get\_token\_from\_keychain()  
    if not token:  
      self.\_respond(  
          {"status": "error", "reason": "Keychain secret not found"}, 500  
      )  
      return

    prompt\_text \= (  
        f"Git Authentication Request\\n\\n"  
        f"Target Path: {repo\_path}\\n"  
        f"Local Context: {commit\_info}\\n"  
        f"Session ID: {session\_id\[:8\]}...\\n\\n"  
        f"Authorize token access for this operation?"  
    )

    applescript \= (  
        f'display dialog "{prompt\_text}" with title "Git Security Gatekeeper"'  
        ' buttons {"Deny", "Authorize"} default button "Deny"'  
    )

    res \= subprocess.run(  
        \["osascript", "-e", applescript\], capture\_output=True, text=True  
    )

    if "button returned:Authorize" in res.stdout:  
      self.\_respond({"status": "approved", "token": token}, 200\)  
    else:  
      self.\_respond(  
          {"status": "denied", "reason": "User rejected request"}, 403  
      )

  def \_respond(self, data, code=200):  
    self.send\_response(code)  
    self.send\_header("Content-Type", "application/json")  
    self.end\_headers()  
    self.wfile.write(json.dumps(data).encode("utf-8"))

  def log\_message(self, format, \*args):  
    pass

def main():  
  listen\_host \= get\_virtual\_bridge\_ip()  
  print(f"\[\*\] Host Auth Proxy listening on {listen\_host}:{LISTEN\_PORT}")  
  server \= HTTPServer((listen\_host, LISTEN\_PORT), AuthProxyHandler)  
  try:  
    server.serve\_forever()  
  except KeyboardInterrupt:  
    print("\\n\[\*\] Shutting down.")

if \_\_name\_\_ \== "\_\_main\_\_":  
  main()

Make it executable and launch it:

chmod \+x \~/bin/git\_host\_proxy.py  
python3 \~/bin/git\_host\_proxy.py

### **Step 2: Ubuntu VM Setup**

#### **A. Create VM Credential Helper Script**

Inside the Ubuntu VM, create /usr/local/bin/vm-git-helper:

\#\!/usr/bin/env python3  
"""Ubuntu VM Git Credential Helper.

Dynamically finds host default gateway and requests ephemeral auth tokens.  
"""  
import json  
import os  
import subprocess  
import sys  
import urllib.request

def get\_default\_gateway() \-\> str:  
  """Extracts default gateway IP directly from Linux routing table."""  
  try:  
    return subprocess.check\_output(  
        "ip route | awk '/default/ {print $3}'", shell=True, text=True  
    ).strip()  
  except Exception:  
    return "192.168.64.1"

def main():  
  if len(sys.argv) \< 2 or sys.argv\[1\] \!= "get":  
    return

  input\_data \= {}  
  for line in sys.stdin:  
    line \= line.strip()  
    if not line:  
      break  
    if "=" in line:  
      key, val \= line.split("=", 1\)  
      input\_data\[key\] \= val

  session\_id \= os.environ.get("GIT\_AUTH\_SESSION", "")

  try:  
    commit\_summary \= subprocess.check\_output(  
        \["git", "log", "-1", "--oneline"\], text=True, stderr=subprocess.DEVNULL  
    ).strip()  
  except Exception:  
    commit\_summary \= "Non-repository or working directory"

  payload \= {  
      "session": session\_id,  
      "protocol": input\_data.get("protocol", "https"),  
      "host": input\_data.get("host", "github.com"),  
      "path": input\_data.get("path", ""),  
      "commit": commit\_summary,  
  }

  host\_ip \= get\_default\_gateway()  
  proxy\_url \= f"http://{host\_ip}:9876/token"

  req \= urllib.request.Request(  
      proxy\_url,  
      data=json.dumps(payload).encode("utf-8"),  
      headers={"Content-Type": "application/json"},  
  )

  try:  
    with urllib.request.urlopen(req, timeout=30) as resp:  
      result \= json.loads(resp.read().decode("utf-8"))  
      if result.get("status") \== "approved" and "token" in result:  
        print("username=x-access-token")  
        print(f"password={result\['token'\]}")  
        sys.exit(0)  
      else:  
        sys.exit(1)  
  except Exception:  
    sys.exit(1)

if \_\_name\_\_ \== "\_\_main\_\_":  
  main()

Make it executable and enable it globally in Git:

sudo chmod \+x /usr/local/bin/vm-git-helper  
git config \--global credential.helper /usr/local/bin/vm-git-helper

### **Step 3: Shell Configuration & AI Wrappers**

Add session exports and sanitized wrappers to \~/.bash\_aliases inside the Ubuntu VM:

\# Generate session handle for interactive human terminal sessions  
if \[ \-z "$GIT\_AUTH\_SESSION" \]; then  
    export GIT\_AUTH\_SESSION="session\_$(head \-c 16 /dev/urandom | xxd \-p)"  
fi

\# Sanitized AI Agent Wrappers  
noclaude() {  
    GIT\_AUTH\_SESSION= SSH\_AUTH\_SOCK= nono run \--allow . \--allow \~/.claude \-- claude "$@"   
}

## **4\. Verification Procedure**

> 1. **Human Interactive Shell:** Open a terminal in the VM and execute git push or git fetch.  
   * *Expected Result:* A macOS dialog appears displaying the repository path, commit summary, and session handle. Clicking **Authorize** allows the operation to complete.  
> 2. **AI Agent Sandbox:** Run noclaude or nogoose inside a VM repository and attempt a Git operation.  
   * *Expected Result:* The operation fails instantly inside the sandbox without displaying a macOS prompt because GIT\_AUTH\_SESSION was stripped.

## **5\. Set on startup**

Modify the XML below, replacing YOUR\_USERNAME, and store it in \~/Library/LaunchAgents/com.user.githostproxy.plist:

\<?xml version="1.0" encoding="UTF-8"?\>  
\<\!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"\>  
\<plist version="1.0"\>  
\<dict\>  
    \<key\>Label\</key\>  
    \<string\>com.user.githostproxy\</string\>

    \<key\>ProgramArguments\</key\>  
    \<array\>  
        \<string\>/usr/bin/python3\</string\>  
        \<string\>/Users/YOUR\_USERNAME/bin/git\_host\_proxy.py\</string\>  
    \</array\>

    \<key\>RunAtLoad\</key\>  
    \<true/\>

    \<key\>KeepAlive\</key\>  
    \<true/\>

    \<key\>StandardOutPath\</key\>  
    \<string\>/tmp/git\_host\_proxy.log\</string\>

    \<key\>StandardErrorPath\</key\>  
    \<string\>/tmp/git\_host\_proxy.err\</string\>  
\</dict\>  
\</plist\>

Now run this to make that run at user startup:

launchctl load \~/Library/LaunchAgents/com.user.githostproxy.plist


