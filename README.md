# OVH VPS + Teleport + GitHub SSO

Ansible project that turns a single Ubuntu/Debian VPS into an all-in-one
**Teleport Community Edition** node (auth, proxy and SSH service on one host)
with **GitHub SSO** for SSH access, deployed through a **manual,
approval-gated GitHub Actions workflow**.

```
you ──(GitHub OAuth)──> Teleport proxy :443 ──> VPS ssh_service :3022
                                  (root / ubuntu logins)
```

## Example deployment

| Item | Value |
| --- | --- |
| Proxy / web UI | `https://vps.example.com` |
| Native SSH (break-glass) | `ssh -p 2222 ubuntu@vps.example.com` |
| Teleport version | latest from the Teleport APT repo (pinnable) |
| Deploy trigger | Actions → **Deploy** → *Run workflow* |

Substitute your own domain/port throughout if you fork this repo.

## What it does

- Validates that the required variables are present, then installs `curl`,
  `gnupg`, `tar` and `ca-certificates`.
- Adds the Teleport APT repository and installs the `teleport` package
  (latest, or a pinned `teleport_version`).
- Writes `/etc/teleport.yaml` with the auth, proxy and SSH services enabled
  on one host, and Let's Encrypt ACME on port 443.
- Creates two Teleport roles (`vps-admin`, `vps-developer`) with static
  `root`/`ubuntu` logins.
- Applies roles and the GitHub OAuth connector with `tctl create --force`, so
  redeploys overwrite them instead of failing with `already exists`.
- Stages the connector in a root-only `/tmp/teleport-bootstrap` directory
  (mode `0700`), disables diff output for it, and deletes the whole directory
  at the end — that is where the OAuth client secret lives on disk.
- Waits for the auth (`3025`) and web (`443`) listeners, validates the sshd
  change with `sshd -t`, and restarts OpenSSH only when it changed.
- Optionally restricts native SSH authentication to a CIDR at the sshd level.

It does **not** manage DNS, a firewall, or the sshd `Port` — those stay
manual (see [Ports and firewall](#ports-and-firewall)).

## Ports and firewall

| Port | Service | Exposure |
| --- | --- | --- |
| `443/tcp` | Teleport proxy (web UI, `tsh`, ACME TLS-ALPN) | **must be public** |
| `3025/tcp` | Teleport auth API — binds `0.0.0.0:3025` | **block at the firewall**; never internet-facing |
| `3022/tcp` | Teleport SSH service — binds `0.0.0.0:3022` | internal only; block at the firewall |
| `2222/tcp` | Native OpenSSH (break-glass), if you use it | restrict to your IP if possible |
| `80/tcp` | Not used | ACME uses 443, not 80 |

The templates bind auth and SSH on **all interfaces**, so the firewall is the
only thing keeping `3022`/`3025` private. This playbook configures no
firewall — open `443` and block `3022`/`3025` in `ufw` or the OVH firewall
yourself.

`ansible_ssh_port` / `VPS_SSH_PORT` only tell Ansible where to connect. The
playbook never edits sshd's `Port`, so `2222` must already be listening on
the VPS (or mapped to `22` by your provider).

## Prerequisites

1. Ubuntu or Debian VPS with an `ubuntu` user and SSH key access.
2. A DNS `A` record (e.g. `vps.example.com`) pointing at the VPS **before**
   the first deploy, or ACME cannot get a certificate.
3. **Inbound TCP 443 open** in the OVH firewall / `ufw`, with
   `3022`/`3025` blocked (see above).
4. The SSH port used by Ansible (default `22`) reachable from your control
   host and, if you deploy from Actions, from GitHub's runners.
5. A **free GitHub organization** that you own. Teleport's GitHub connector can
   only map org teams, so a bare personal account cannot log in — but a
   one-person org can, and you stay its only member (see Step 1).
6. For local deploys, **Python 3.11+** and `uv` on the control host. The
   Actions workflow uses Python 3.12 and installs `ansible>=12,<13` from
   `requirements.txt`.

## Quick start

1. Create a free org with yourself as the only member (use its built-in
   `owners` team as the admin team), and the OAuth app (Steps 1–2).
2. `cp vars.example.yml vars.yml` and fill it in (Step 3).
3. Deploy locally with `bash scripts/local-test.sh` (Step 4).
4. Push the repo, add Actions variables/secrets, run the workflow (Step 5).
5. Log in with `tsh login --proxy=<domain> --auth=github`.

---

## Step 1 — GitHub organization (solo setup)

Teleport's GitHub connector maps **organization teams** to Teleport roles. It
has no way to map a bare personal account, the old `teams_to_logins` field was
removed in Teleport 12, and `users_to_logins` was never a valid GitHub
connector field. So GitHub SSO always needs an org — but it can be a **free
one-person org that you own**. Nothing is shared, nobody else joins, and no
paid plan is involved.

1. Create a free organization: github.com → **New organization** (free plan),
   then add your personal account as the sole **Owner**.
2. Use the org's built-in **`owners`** team as `github_admin_team` — you do not
   have to create a team at all. If you prefer an explicit name, create a team
   such as `vps-admins` and add yourself to it.
3. Only if you later want non-root users: create a second team (e.g.
   `vps-devs`) and set it as `github_developer_team`.

To give someone else access later, invite them to the org and the admin team.
Mapping happens by team membership at login time, so no redeploy is needed.

The playbook creates these roles:

| Teleport role | GitHub team variable | SSH logins |
| --- | --- | --- |
| `vps-admin` | `github_admin_team` (often `owners`) | `root`, `ubuntu` |
| `vps-developer` | `github_developer_team` (optional) | `ubuntu` |

Anyone in the admin team can become `root`. With `owners` that is just you
(plus any co-owner you add), which is what you want on a personal VPS.

> Team and org names must be **slugs**: lowercase, hyphens instead of spaces.
> `VPS Admins` → `vps-admins`. The built-in owners team is always `owners`,
> even though the UI labels it "Owners".

## Step 2 — Create the GitHub OAuth app

GitHub → Settings → Developer settings → **OAuth Apps** → New OAuth App:

- **Application name**: anything, e.g. `Teleport VPS`
- **Homepage URL**: `https://vps.example.com`
- **Authorization callback URL**:
  `https://vps.example.com/v1/webapi/github/callback`

> This field is the OAuth **redirect URI**; GitHub sometimes labels it just
> **Callback URL** and lets you add several. It must match the connector's
> `redirect_url` exactly — `https`, no trailing slash, path
> `/v1/webapi/github/callback`. Make sure you are in **OAuth Apps**, not
> **GitHub Apps**: the two are different products and only OAuth Apps work
> with Teleport's GitHub connector.
>
> Use the **same hostname** here that you put in `teleport_domain_or_ip`.
> Two names pointing at the same IP are not interchangeable: the ACME
> certificate, the OAuth redirect URI, cookies/WebAuthn and the cluster name
> are all bound to that one hostname. Only one name can be the Teleport
> identity at a time.

Copy the **Client ID** and generate a **Client Secret**.

> Treat the secret as compromised if it has ever been pasted into a local
> `vars.yml`, a chat, an issue, or a log. Generate a new one in the OAuth app
> and update it everywhere; deleting the file that held it is not enough.

If the OAuth app is owned by your personal account but reads teams from an
organization, the org must allow third-party OAuth apps
(Organization settings → Third-party access) and grant this app access.
Creating the OAuth app under the org instead (Org settings → Developer
settings → OAuth Apps) skips that approval step; either works for a solo org.

Ownership of these pieces is independent: the repo can live in your personal
account, the OAuth app can be personal, and the org only needs to contain you.
Teleport never reads the repo — it only asks GitHub for your org teams.

## Step 3 — Local variables

```bash
cp vars.example.yml vars.yml
$EDITOR vars.yml
```

Required:

| Variable | Example | Notes |
| --- | --- | --- |
| `teleport_domain_or_ip` | `vps.example.com` | DNS name for TLS |
| `teleport_acme_email` | `you@example.com` | ACME/Let's Encrypt contact address; use a real mailbox (unrelated to login) |
| `github_org` | `my-org` | org slug; a one-person org is fine |
| `github_admin_team` | `owners` | team slug; `owners` exists in every org |
| `github_oauth_client_id` | `Ov23li...` | public value |
| `github_oauth_client_secret` | `...` | **secret** |

Optional: `ansible_ssh_port` (default `22`), `github_developer_team`,
`ssh_control_allow_cidr`, `ansible_ssh_private_key_file`, `teleport_version`.

`vars.yml` is gitignored and must never be committed. Local runs load it with
`-e @vars.yml`; the target host still comes from `inventory.ini`, which is
hardcoded to `vps.example.com` — change it (or pass `-i`) when you fork
this repo. The Actions workflow overrides host, user and port with `-e`, so
`inventory.ini` does not matter there.

## Step 4 — Deploy locally

```bash
uv venv .venv
source .venv/bin/activate
uv pip install -r requirements.txt

bash scripts/local-test.sh
# equivalent to: ansible-playbook playbook.yml -e "@vars.yml"

# dry run first if you prefer:
bash scripts/local-test.sh --check --diff
```

`ansible.cfg` sets `host_key_checking = False` and enables SSH pipelining, so
local deploys do not verify the VPS host key. The Actions workflow re-enables
checking with `ANSIBLE_HOST_KEY_CHECKING=True` after pinning the key via
`ssh-keyscan`; consider passing the same env var locally if you want that
protection.

In `--check` mode the `tctl create --force` tasks are skipped (package and
config changes are still reported), so a clean dry run does not prove the
roles or connector would apply.

Verify on the VPS:

```bash
sudo systemctl status teleport --no-pager
sudo tctl status
sudo tctl get github/github
curl -sS https://vps.example.com/webapi/ping
```

## Step 5 — Deploy from GitHub Actions

The workflow is **manual only** (`workflow_dispatch`): Actions tab →
**Deploy** → *Run workflow*. Nothing deploys on push. A dry run is available
via the `check_mode` input.

### Environment and approval gate

The job targets the **`production`** environment
(Settings → Environments → `production`). Configure:

- **Required reviewers** → every deploy waits for your approval.
- **Deployment branches** → `main` only.

GitHub creates the environment automatically on the first run, but add the
protection rules *before* the first deploy. Store the values below as
**environment** variables/secrets so the gate applies to them.

> On GitHub Free, Pro and Team plans, required reviewers only work on **public**
> repositories. A private personal repo can still deploy, but the manual
> approval gate needs GitHub Enterprise — otherwise use `check_mode` and run
> the workflow yourself, or deploy locally.

### Variables (non-sensitive)

Settings → Environments → `production` → **Environment variables**:

| Variable | Required | Example |
| --- | --- | --- |
| `VPS_HOST` | yes | `vps.example.com` |
| `TELEPORT_DOMAIN` | yes | `vps.example.com` |
| `GITHUB_ORG` | yes | `my-org` |
| `GITHUB_ADMIN_TEAM` | yes | `owners` (or a team you created) |
| `GITHUB_OAUTH_CLIENT_ID` | yes | `Ov23li...` (public by design) |
| `VPS_USER` | no | `ubuntu` (default) |
| `VPS_SSH_PORT` | no | `2222` |
| `TELEPORT_ACME_EMAIL` | no | defaults to `admin@<domain>` — set a real address, since that mailbox may not exist |
| `GITHUB_DEVELOPER_TEAM` | no | `vps-devs` |

### Secrets (encrypted)

Settings → Environments → `production` → **Environment secrets**:

| Secret | Required | Notes |
| --- | --- | --- |
| `VPS_SSH_PRIVATE_KEY` | yes | private half of an authorized key |
| `GITHUB_OAUTH_CLIENT_SECRET` | yes | OAuth app client secret |
| `SSH_CONTROL_ALLOW_CIDR` | no | `203.0.113.10/32`; kept secret so your IP isn't published |

### Set them from the CLI

```bash
# non-sensitive configuration
gh variable set VPS_HOST --env production --body "vps.example.com"
gh variable set TELEPORT_DOMAIN --env production --body "vps.example.com"
gh variable set VPS_SSH_PORT --env production --body "2222"
gh variable set GITHUB_ORG --env production --body "my-org"
gh variable set GITHUB_ADMIN_TEAM --env production --body "owners"
gh variable set GITHUB_OAUTH_CLIENT_ID --env production --body "Ov23li..."

# secrets (prompted, never on the command line)
gh secret set VPS_SSH_PRIVATE_KEY --env production < ~/.ssh/deploy_key
gh secret set GITHUB_OAUTH_CLIENT_SECRET --env production
```

### What the workflow does

1. Installs Ansible from `requirements.txt`.
2. Validates that all required values are present.
3. Writes the private key to `~/.ssh/deploy_key` (mode `600`) and pins the
   host key with `ssh-keyscan`; `ANSIBLE_HOST_KEY_CHECKING=True`.
4. Renders `vars.ci.yml` from the variables/secrets.
5. Runs the playbook with `--check --diff` when `check_mode` is set.
6. Deletes `vars.ci.yml` in an `if: always()` step.

### Workflow inputs

- `check_mode` — report changes without applying them.
- `teleport_version` — pin a package version; blank means latest.

## Secrets and public repositories

Nothing sensitive is committed. GitHub stores Actions secrets encrypted
(libsodium sealed box), keeps them write-only, excludes them from clones,
forks and release tarballs, and masks them in logs. A public repo exposes the
code, not the secrets.

- Keep credentials in **secrets**, not variables. Variables are readable in
  repository/environment settings.
- This workflow is `workflow_dispatch`-only, so a fork PR cannot run it or
  read secrets. Do not add `pull_request_target` workflows that check out fork
  code.
- Enable **Settings → Code security → Secret scanning** and **Push
  protection**; they are free on public repos and block accidental credential
  commits.
- Log masking only matches the exact secret string. Avoid `echo`/`printenv`
  of secrets and avoid `--diff` on secret-bearing tasks (the connector
  template sets `diff: false` for this reason).
- `vars.yml` (local) and `vars.ci.yml` (generated in CI) are gitignored.
- A secret that has been pasted into `vars.yml`, a chat, or a log is
  compromised even if the file is ignored or deleted. Rotate it in the OAuth
  app and update both the GitHub secret and local `vars.yml`.
- The deploy SSH key is root-equivalent because Ansible uses `sudo`. Use a
  dedicated key and remove it from `authorized_keys` if it leaks.

Alternatives if you do not want secrets in GitHub at all:

- **SOPS + age** — encrypted `vars.yml` in the repo, one age key as the only
  secret.
- **External secret manager** — 1Password/Bitwarden/Vault/AWS Secrets Manager
  fetched at run time with a short-lived token.
- **Local-only deploys** — `scripts/local-test.sh`, no Actions.

## Daily use

```bash
# Browser-based GitHub login
tsh login --proxy=vps.example.com --auth=github

# Admin
tsh ssh root@vps.example.com
tsh ssh ubuntu@vps.example.com

# Any login allowed by your role
tsh ls
tsh ssh vps.example.com
```

The web UI is at `https://vps.example.com`.

No browser on this machine? Run `tsh login --browser=none
--proxy=vps.example.com --auth=github`, open the printed URL on any
device, then paste the redirect URL back. This still uses the same callback
flow — GitHub's device flow is not used by Teleport's GitHub connector.

### Break-glass access

GitHub SSO is the primary login. Native SSH still works:

```bash
ssh -p 2222 ubuntu@vps.example.com
```

To add a local Teleport admin (useful if GitHub OAuth breaks):

```bash
sudo tctl users add teleport-admin --roles=vps-admin --logins=root,ubuntu
```

Open the printed URL to set a password and MFA.

## Day-2 operations

| Task | How |
| --- | --- |
| Change domain | Update `teleport_domain_or_ip` / `TELEPORT_DOMAIN`, `inventory.ini`, DNS, and the OAuth callback URL, then redeploy |
| Add a developer team | Set `github_developer_team` / `GITHUB_DEVELOPER_TEAM`, add members, redeploy |
| Add another admin | Invite them to the org and to `github_admin_team` (`owners` or your own team). No redeploy needed — teams are read from GitHub at login |
| Rotate the OAuth secret | Generate a new secret in the OAuth app, update the GitHub secret **and** local `vars.yml`, redeploy |
| Pin Teleport | Set `teleport_version` locally, or pass the `teleport_version` workflow input |
| Change SSH port | Update `ansible_ssh_port` / `VPS_SSH_PORT` **and** the sshd/OVH port mapping; the playbook only changes where Ansible connects |
| Disable native SSH lockdown | Remove `ssh_control_allow_cidr`; the playbook deletes the sshd block and restarts SSH |

Role and connector updates are applied with `tctl create --force`, so
redeploying overwrites them in place rather than duplicating them.

## Troubleshooting

**No certificate / HTTPS fails** — Port 443 must be reachable from the
internet and DNS must already point at the VPS. Teleport ACME uses
TLS-ALPN-01 on 443, not port 80.

```bash
sudo journalctl -u teleport -n 200 --no-pager | grep -i acme
curl -sS https://vps.example.com/webapi/ping
```

**`tctl` says permission denied** — run it as root on the host that runs the
auth service. `tctl` reads `/etc/teleport.yaml` automatically; the correct
override variable is `TELEPORT_CONFIG_FILE` (not `TELEPORT_CONFIG`).

**GitHub login has no roles / says "no teams"** — Teleport can only read teams
from an **organization**, so a personal account that belongs to no org cannot
log in through the GitHub connector, no matter how the connector is configured.
Create a free org, make yourself an owner, and set `github_org` to it.

**Login works but `tsh ssh` fails** — the team did not map to a role, or the
role does not allow the login:

```bash
sudo tctl get github/github
sudo tctl get role/vps-admin
sudo tctl get users
```

Check that org/team values are slugs, that the user is a member of the team,
and that the OAuth app is authorized for the organization
(Organization settings → Third-party access).

**`already exists` errors** — the playbook uses `tctl create --force`, so
resources are overwritten. If you renamed a role/connector, the old resource
remains; delete it with `tctl rm <kind>/<name>`.

**Actions cannot connect** — check that the VPS firewall allows the runner,
that `VPS_SSH_PRIVATE_KEY` matches an authorized key, that the environment
approval has been granted, and that `ssh_control_allow_cidr` does not exclude
GitHub's (dynamic) runner addresses.

**Workflow is waiting** — a required reviewer has to approve the run
(Actions → the run → *Review deployments*).

**Local deploy connects to the wrong host** — `ansible.cfg` points at
`inventory.ini`, which is hardcoded to `vps.example.com`. Edit that
file or override with `-i` / `-e ansible_host=...`.

**`Callback dispatch 'v2_on_file_diff' failed ... 'AnsibleDumper' is not defined`**
— harmless warning from the `community.general` `yaml` stdout callback, which
is incompatible with ansible-core 2.19 (`AnsibleDumper` became a factory
function, so its subclassing fails). It only affects `--diff` rendering; the
run itself is fine. This repo's `ansible.cfg` uses the builtin callback with
`callback_result_format = yaml` instead — remove any `stdout_callback = yaml`
override, or upgrade `ansible` / `community.general`.

**`--check` reports no changes for roles or the connector** — expected. The
`command` tasks (`tctl create --force`) are skipped in check mode; only
package, config and sshd changes are reported.

**`3022` or `3025` answers from the internet** — this playbook configures no
firewall and Teleport binds both on `0.0.0.0`. Block them in `ufw` or the
OVH firewall.

## Repo tooling (OpenCode)

The repo ships an OpenCode configuration in `.opencode/`:

- `opencode.jsonc` pins `opencode/deepseek-v4.1-flash-free` with a Hugging
  Face fallback (`HF_TOKEN`), and defines the permission guardrails: shell
  asks by default, read-only inspection and `git add` are allowed,
  destructive commands ask, and `git commit` / `git push` are denied. Edits
  to `.opencode/`, `.git/`, `AGENTS.md` and `*.env*` ask first.
- `agents/quick.md` is a terse pair-programmer agent.
- `commands/commit.md` stages the change and proposes a commit message
  without committing; `commands/review.md` reviews the working diff.

## Repository layout

| Path | Purpose |
| --- | --- |
| `playbook.yml` | Install, configure, start, and apply roles + GitHub connector |
| `ansible.cfg` | Inventory path, YAML output, pipelining, host-key checking off |
| `requirements.txt` | `ansible>=12,<13` for local and CI installs |
| `templates/teleport.yaml.j2` | Teleport services, proxy on 443, ACME |
| `templates/teleport-role.yaml.j2` | Teleport RBAC role template |
| `templates/github-connector.yaml.j2` | GitHub OAuth connector (`teams_to_roles`) |
| `vars.example.yml` | Template for local variables; copy to `vars.yml` |
| `vars.yml` | Local secrets/config — gitignored, never commit |
| `inventory.ini` | Inventory entry for the VPS (hardcoded host) |
| `.github/workflows/deploy.yml` | Manual, approval-gated deploy |
| `scripts/local-test.sh` | Local helper around `ansible-playbook` |
| `.opencode/` | OpenCode agent, commands and permission config |
| `.gitignore` | Excludes `vars.yml`, `vars.ci.yml`, keys and venv |
