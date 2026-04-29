# __APP_NAME__

A [quickship](https://github.com/your-org/quickship-platform) app — a small internal tool you build and ship by talking to Claude. The platform handles the boring 80% (auth, database, file storage, email, AI), so you can focus on what the app actually *does*.

You don't run terminal commands by hand. You describe what you want; Claude makes the change, runs it locally so you can try it, and deploys it when you're happy.

<!-- TEMPLATE-ONLY:START -->
## Getting started

This page is the **template** — read on if you want to create your own app from it. (After you bootstrap, this section disappears and the rest becomes your app's README.)

### 1. Install the requirements listed below

[Claude Code](https://claude.com/claude-code), [Docker Desktop](https://www.docker.com/products/docker-desktop/), and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html). Plus `git` (pre-installed on macOS/Linux) and SSH keys set up for whichever host your platform admin uses (GitHub or GitLab).

If your destination is GitHub and you want Claude to be able to create the repo with one command, also install [GitHub CLI](https://cli.github.com/) (`gh`) and run `gh auth login`. For GitLab, create the repo via the web UI when prompted; everything else (`git push`, pipeline triggers) is identical regardless of host.

### 2. Set up AWS access (one-time)

Before you can create or deploy any app, your machine needs to be able to reach the platform's AWS account. **You only do this once** — every future app reuses the same setup.

**You'll need from your platform admin:**
- An **access key ID** (looks like `AKIA…`).
- A **secret access key** (a longer random string).

The admin generates these by running:
```bash
aws iam create-access-key --user-name quickship-developer-<your-name>
```
…and sends the values to you over a secure channel (1Password, Bitwarden Send, Signal). Don't accept them via email or Slack DM.

**On your machine** — your platform admin will tell you the **prefix** for your platform (e.g., `quickship`, `acme-platform`). Use that prefix as your profile name:

```bash
# Replace 'quickship' with your platform's prefix if different
aws configure --profile quickship
```

When prompted, paste the values:
- **AWS Access Key ID**: paste the `AKIA…` value
- **AWS Secret Access Key**: paste the secret
- **Default region name**: `eu-central-1` (or whatever your platform runs in)
- **Default output format**: `json`

**Verify it works:**

```bash
aws sts get-caller-identity --profile quickship
```

You should see output ending in `user/<prefix>-developer-<your-name>`. That's it — `bootstrap.sh` will ask for the prefix once when you scaffold an app and record it in the project, so subsequent commands don't need any environment-variable dance.

If anything fails here, just tell Claude what the error said. It can read the AWS CLI's output and walk you through the fix.

### 3. Create your app from this template

Pick a short name for your app (lowercase, hyphens, e.g. `expense-tracker`):

```bash
git clone --depth=1 https://github.com/stadskle/quickship-app-template.git your-app-name
cd your-app-name
./bootstrap.sh
```

This works the same regardless of where your app will eventually live (GitHub, GitLab, whichever your platform admin set up). You'll handle the destination repo together with Claude on the first `/deploy` — no need to decide right now.

`bootstrap.sh` asks just two things — everything else (account ID, region, platform modules URL, your developer name) is read from your AWS profile or platform-published SSM:
- **App name** (defaults to the folder name)
- **Allowed users** — comma-separated email addresses or `*@yourcompany.com` wildcards (who can reach the deployed app via Cloudflare Access)

Capabilities (Postgres, S3, DynamoDB, SES, Bedrock AI) all start **off** — Claude turns them on as you describe what you're building. You don't need to pick anything upfront.

The script substitutes your answers throughout the scaffold, deletes itself, and commits as your starting point.

### 4. Open in Claude Code

```bash
claude .
```

Talk to Claude — read the rest of this README to see the kinds of things you can ask. The `.claude/` folder ships with slash commands (`/deploy`, `/local`, `/migrate`, `/route`, `/review`) and a security-reviewer subagent already configured.

### 5. First deploy

When you're ready to put your app live, ask Claude `/deploy`. The first deploy creates the CI/CD pipeline; after that, every `git push` ships automatically — no manual deploy step needed.

<!-- TEMPLATE-ONLY:END -->

## What you need on your machine

- **[Claude Code](https://claude.com/claude-code)** — the agent you'll be talking to.
- **[Docker Desktop](https://www.docker.com/products/docker-desktop/)** — Claude uses it to run the app on your laptop. Just install it; you don't need to learn it.
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)** — Claude uses it to read logs, check pipeline status, and inspect AWS resources when something looks off.
- **`git`** — pre-installed on macOS and Linux. SSH keys configured for whichever git host your platform admin uses (GitHub or GitLab) so `git push` works.
- **(Optional, GitHub-only)** [GitHub CLI](https://cli.github.com/) (`gh`) — Claude uses `gh repo create` to make your app's repo on the first deploy. GitLab users create the repo via the web UI when prompted; after that `git push` is identical regardless of host. The pipeline detects pushes via AWS CodeConnections, not via any CLI.

That's it. No Python, no Node, no Terraform setup — Claude has those handled inside Docker.

If any of those four aren't installed yet, just tell Claude — it can walk you through installing and logging in.

## How you work with this app

Open this folder in Claude Code and just talk to it. Some examples:

> "Show me the app running locally."
> Claude starts everything in Docker and gives you a link to open in the browser. Edit the conversation, and Claude makes changes — they show up in the browser as you go.

> "Add a page where I can upload a CSV and see the rows."
> Claude writes the backend route, the React page, and any database table needed. You try it locally first.

> "Send me an email when someone submits the form."
> Claude wires up the email helper. Locally it prints to the console; once deployed, it sends real email.

> "Ship it."
> The first time, Claude sets up the deployment pipeline — your app appears at `https://__APP_NAME__.<your-platform-zone>` a few minutes later (longer on the very first deploy while DNS propagates). After that, every change flows automatically: when Claude pushes your code, the pipeline picks it up, builds it, and deploys to AWS without you having to ask.

If something breaks, tell Claude what you saw — it can read logs, fix the code, and redeploy.

## Where things live

You usually don't need to touch these files directly — Claude does. But for orientation:

```
__APP_NAME__/
├── backend/                 # The API + database logic (Python)
│   ├── app/main.py          # routes (the URLs your app responds to)
│   └── migrations/          # database schema changes
├── frontend/                # The web UI (React)
│   └── src/                 # pages and components
├── infra/                   # Deployment config (Terraform — Claude runs this)
├── CLAUDE.md                # Instructions Claude reads to stay on the rails
└── .claude/commands/        # Shortcuts you can type (e.g. /deploy, /migrate)
```

## Things worth knowing

- **Logins are handled for you.** When the app is deployed, only people you've invited (in the platform's Cloudflare Access settings) can reach it. The app sees their email in every request — no passwords, no signup forms to build.
- **Locally, you're "dev@local".** The local app skips the login wall so you can try things fast. Real auth kicks in once deployed.
- **The database is shared infrastructure, but your app gets its own private piece of it.** You don't manage the database server.
- **Email, file uploads, and AI calls "just work"** — there are pre-built helpers Claude knows about. Ask for the feature; Claude wires the helper.

## If you get stuck

- Tell Claude what's wrong in plain language. ("The deploy failed", "The page is blank", "I don't see my email in the form".) It can investigate.
- The `/deploy`, `/local`, `/migrate`, `/route` slash commands in Claude Code are quick shortcuts for common asks.
- If Claude proposes something that changes how *deployment* works (anything in the `infra/` folder), it'll pause and ask before applying — those changes affect real cloud resources.

## For the curious / for developers

Implementation details, conventions, and helper APIs live in [CLAUDE.md](./CLAUDE.md). That file is written for Claude, but it's also the right place to look if you want to understand what's actually happening under the hood.
