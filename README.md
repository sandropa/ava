# ava — opencode agent behind agent-vault, on one VPS

Two Docker containers on one Hetzner VPS:

- **vault** — [agent-vault](https://docs.agent-vault.dev) credential broker. Holds the
  encrypted store and a MITM proxy. Real secrets live only here.
- **agent** — [opencode](https://opencode.ai) running under `agent-vault run`, so all its
  HTTP(S) traffic is routed through the vault. The agent only ever holds placeholder
  strings (e.g. `__github_token__`); the vault swaps in the real value at the proxy.

**Goal of this first cut:** SSH in → attach to the agent's tmux → run opencode → watch it
open a PR against a branch-protected repo using its own GitHub account. Model calls use
opencode's free models (no key needed yet). The only secret the vault protects right now is
the agent's GitHub PAT.

```
you ──ssh──▶ VPS
              ├─ container: vault   (127.0.0.1:14321 UI, :14322 proxy, internal only)
              └─ container: agent   (opencode; egress → vault:14322 → github.com)
```

Later slots (3 agents), opencode go (paid models), and Telegram are noted at the bottom — not
built yet.

---

## Prerequisites

- VPS reachable over SSH, sudo, port 22 the only inbound (as you have it).
- The agent's GitHub account exists, is a **collaborator** on the target repo, the repo has
  **branch protection requiring a PR + your approval**, and you have a **PAT** for that
  account with `repo` scope.
- Docker + compose plugin on the VPS:
  ```bash
  curl -fsSL https://get.docker.com | sh
  ```

Nothing here publishes 14321/14322 to the internet — 14321 binds to `127.0.0.1` (reach the
UI via SSH tunnel), 14322 stays on the internal Docker network. Keep it that way.

---

## One-time setup

### 1. Clone this repo onto the VPS and set the env

```bash
git clone <this-repo> ava && cd ava
cp .env.example .env
chmod 600 .env
# generate a random master password into .env (AGENT_VAULT_TOKEN stays blank until step 4):
sed -i "s|^AGENT_VAULT_MASTER_PASSWORD=.*|AGENT_VAULT_MASTER_PASSWORD=$(openssl rand -hex 16)|" .env
```

### 2. Build

```bash
sudo docker compose build
```

### 3. Start the vault

No interactive prompts: the master password is read from `.env`, and the owner account is
created from the UI in the next step. Just start it detached:

```bash
sudo docker compose up -d vault
curl -sI http://127.0.0.1:14321/health    # expect HTTP/1.1 200
```

### 4. Configure the vault via its UI

From your **laptop**, tunnel to the UI:

```bash
ssh -L 14321:127.0.0.1:14321 <user>@<vps-ip> -N
```

Open <http://localhost:14321>, **create the owner account** (the register page the server
pointed you to), log in, then:

1. Use the existing **`default`** vault (auto-created with your account) — no need to make a new one.
2. **Credentials → Add credential** (twice):
   - `GITHUB_TOKEN` = the agent account's PAT.
   - `GIT_USERNAME` = `x-access-token` (not secret — it's the Basic-auth username git push needs).
3. **Services → Add service** — two, because git push and the API use different hosts *and*
   different auth encodings, both brokered so the PAT never lands in the container:

   - Name **`github-api`**, host **`api.github.com`** — Auth **Passthrough**. Expand **URL
     Substitutions** and add one: replace `__github_token__` in surface **`header`** only
     (gh sends it as an `Authorization` header) with value of credential `GITHUB_TOKEN`.
   - Name **`github-git`**, host **`github.com`** — Auth **Basic**. Both fields take a
     *credential key*, not a literal: username credential key `GIT_USERNAME`, password
     credential key `GITHUB_TOKEN`. No substitution here: git sends Basic auth base64-encoded,
     so the broker must *build* the header itself rather than string-match.

4. **Instance-level `Agents` (left nav, not the vault's Agents tab) → Add agent:**
   - Agent name: `opencode-1`.
   - **Instance role: `No Access`** (least privilege — it only operates in vaults you grant).
   - **Vault access → + Add vault → `default`, role `Proxy`.**
   - **Add**, then copy the token from the Connect modal → that's your `AGENT_VAULT_TOKEN`.

### 5. Give the agent its token and start it

```bash
# on the VPS, edit .env:  AGENT_VAULT_TOKEN=<token from step 4's Connect modal>
# (ignore ADDR/VAULT in the modal — compose.yaml already sets those; only the token is needed)
sudo docker compose up -d agent
sudo docker compose logs -f agent     # expect token validation OK, no crash-loop
```

The agent container fast-fails if the token is missing/invalid — that's why it comes up last.

> **Admin CLI:** don't install `agent-vault` on the host (ignore the `get.agent-vault.dev`
> installer the UI suggests). Run admin commands inside the container instead, e.g. rotate a
> token: `sudo docker compose exec vault agent-vault agent rotate <name>`.

---

## Daily use: run opencode, get a PR

```bash
ssh <user>@<vps-ip>
cd ava
sudo docker compose exec agent tmux attach -t work   # brokered shell inside the agent
```

Inside that shell:

```bash
opencode auth login          # pick a free model provider (re-run after a --force-recreate)
gh auth status               # should show the agent's GitHub account via the brokered API
git clone https://github.com/<owner>/<repo> && cd <repo>
opencode                     # give it a task: make a change, push a branch, open a PR
```

Detach tmux with `Ctrl-b d`; the session keeps running. Reattach any time with the
`tmux attach` line above.

**Verify success:** the PR shows up on GitHub authored by the agent account, marked "review
required" by branch protection. Approve it yourself to merge.

**Reset after the PR closes.** One task = one PR = one container lifetime. Anything the agent
installed or wrote (global packages, files, configs) persists in the running container until
you recreate it. Once the PR is merged or rejected, wipe the slate — this also clears any
persistence a compromise could have planted:

```bash
sudo docker compose up -d --force-recreate agent
```

---

## Gotchas to check on first run

- **git push auth (`github.com`):** handled by the `github.com` service using **Basic** auth
  (broker builds the header), not substitution — see setup step 3. If push still fails auth,
  confirm the agent's git credential helper is supplying *a* username/password so git sends a
  Basic header for the broker to replace (the agent image sets this in `--system` git config).
- **Free-model traffic through the proxy:** `agent-vault run` routes *all* egress through the
  MITM proxy. If opencode's free-model host isn't a known service, add it in the UI as a
  **Passthrough** service (no substitution) so the proxy forwards it.
- **Proxy address from `/discover`:** the agent learns the proxy from the vault. It should
  resolve to `vault:14322` over the compose network; if calls hang, that's the first thing
  to check in `sudo docker compose logs agent`.

---

## Later (not built yet)

- **More agents:** copy the `agent` service to `agent-2`, `agent-3` in `compose.yaml`,
  each with its own `AGENT_VAULT_TOKEN` (one agent identity per slot in the vault). Same
  image, no volumes.
- **opencode go (paid models):** same brokering pattern as GitHub — add the opencode key as
  a vault credential + a service for opencode's gateway host, substituting a placeholder, so
  the real key never lands in the container. (Confirm the exact host + auth header/env var
  from opencode go's docs when you switch off free models.)
- **Telegram:** add the bot token as a credential + `api.telegram.org` service, then wire the
  gateway. (agent-vault's Hermes guide covers the pattern.)
- **Tailscale / tighter egress:** currently the agent container has open egress by default;
  the vault only guarantees secrets aren't leaked (the agent never holds them). Kernel-level
  egress lockdown is agent-vault's `--isolation=container` mode — a later hardening step.
