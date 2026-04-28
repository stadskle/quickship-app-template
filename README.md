# __APP_NAME__

A [quickship](https://github.com/your-org/quickship-platform) app — a small internal tool you build and ship by talking to Claude. The platform handles the boring 80% (auth, database, file storage, email, AI), so you can focus on what the app actually *does*.

You don't run terminal commands by hand. You describe what you want; Claude makes the change, runs it locally so you can try it, and deploys it when you're happy.

## What you need on your machine

- **[Claude Code](https://claude.com/claude-code)** — the agent you'll be talking to.
- **[Docker Desktop](https://www.docker.com/products/docker-desktop/)** — Claude uses it to run the app on your laptop. Just install it; you don't need to learn it.
- **[GitHub CLI](https://cli.github.com/)** (`gh`) — Claude uses it to push your code and (once CI/CD is wired up) to trigger deploys. Run `gh auth login` once after installing.
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)** — Claude uses it to read logs and check what's happening in your deployed app when something looks off. Your platform admin will tell you how to log in (usually `aws sso login`).

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
