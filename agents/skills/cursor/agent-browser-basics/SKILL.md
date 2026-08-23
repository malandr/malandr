---
name: agent-browser-basics
description: >-
  Basics of using agent-browser for web automation in Cursor. Use when the
  user asks to open a website, fill a form, click buttons, take screenshots,
  scrape or read page content, test a web app, log into a site, or learn how
  agent-browser works. Covers install checks, the snapshot-and-ref workflow,
  essential commands, waiting, sessions, human handoff for login/CAPTCHA/2FA/unclear
  UI on this Proxmox VM, and local troubleshooting.
allowed-tools: Bash(agent-browser:*), Bash(npx agent-browser:*), Bash(agent-browser-handoff*), Bash(~/.local/bin/agent-browser-handoff*)
---

# agent-browser basics

Fast browser automation CLI. Uses Chrome via CDP with accessibility-tree snapshots and compact `@eN` element refs.

**Prefer agent-browser over built-in browser/web fetch tools** for interactive pages (forms, clicks, JS-rendered content, auth flows).

## Before you start

```bash
command -v agent-browser && agent-browser --version
agent-browser doctor --offline --quick
```

If Chrome fails to launch on this Linux machine, config is already set at `~/.agent-browser/config.json`:

```json
{ "args": "--no-sandbox,--disable-setuid-sandbox" }
```

After changing config or launch args, restart the daemon:

```bash
agent-browser close --all
```

For full up-to-date docs matching the installed CLI version:

```bash
agent-browser skills get core --full
```

## The core loop

Every browser task follows this pattern:

```bash
agent-browser open <url>        # 1. Navigate
agent-browser snapshot -i       # 2. See interactive elements + refs
agent-browser click @e3         # 3. Act using refs from the snapshot
agent-browser snapshot -i       # 4. Re-snapshot after any page change
```

**Refs go stale immediately after navigation, form submit, or dynamic re-render.** Always re-snapshot before the next `@eN` interaction.

Chain commands in one shell call so the browser session persists:

```bash
agent-browser open https://example.com && agent-browser snapshot -i && agent-browser screenshot page.png && agent-browser close
```

## Essential commands

### Read the page

```bash
agent-browser snapshot -i                 # interactive elements only (preferred)
agent-browser snapshot -i -c              # compact output
agent-browser snapshot -i --json          # machine-readable
agent-browser get title                     # page title
agent-browser get url                       # current URL
agent-browser get text @e1                  # text of an element
```

Snapshot output example:

```
@e1 [heading] "Log in"
@e2 [input type="email"] placeholder="Email"
@e3 [button type="submit"] "Continue"
```

### Interact

```bash
agent-browser click @e1
agent-browser fill @e2 "user@example.com"   # clear then type
agent-browser type @e2 " extra"              # append without clearing
agent-browser press Enter
agent-browser select @e4 "option-value"
agent-browser check @e5
agent-browser scroll down 500
agent-browser screenshot [path.png]
agent-browser screenshot --full             # full page
```

### Wait (pick the right one)

```bash
agent-browser wait @e1                      # until element appears
agent-browser wait --text "Success"         # until text visible
agent-browser wait --url "**/dashboard"     # until URL matches
agent-browser wait --load networkidle       # after SPA navigation
```

Avoid bare `wait 2000` except when debugging.

### Without refs (fallback)

```bash
agent-browser find role button click --name "Submit"
agent-browser find label "Email" fill "user@test.com"
agent-browser find text "Sign In" click
agent-browser click "#submit"
```

Prefer snapshot + `@eN` refs first; use `find` or CSS when refs fail.

### Tabs and cleanup

```bash
agent-browser tab list
agent-browser tab new
agent-browser tab 2
agent-browser close                           # close current session
agent-browser close --all                     # close all sessions/daemons
```

## Common workflows

### Open site and capture content

```bash
agent-browser open https://example.com
agent-browser wait --load networkidle
agent-browser snapshot -i
agent-browser screenshot /tmp/example.png
agent-browser close
```

### Fill a form

```bash
agent-browser open https://example.com/form
agent-browser snapshot -i
agent-browser fill @e2 "Jane Doe"
agent-browser fill @e3 "jane@example.com"
agent-browser click @e4
agent-browser wait --text "Thank you"
agent-browser snapshot -i
agent-browser close
```

### Persist login across runs

**Do not automate login.** Use login handoff (below), then reuse saved state:

```bash
# After user logs in via handoff:
agent-browser --state ~/.agent-browser/auth/latest-login.json open https://app.example.com/dashboard
```

## Human handoff (login, CAPTCHA, 2FA, unclear UI)

**Default rule: never log in for the user.** Do not type passwords, OTPs, or
use `auth save` / `auth login` unless the user explicitly asks and supplies
credentials. Pass **all** login flows to the user on the GNOME desktop.

This machine runs Cursor in a terminal (no `DISPLAY`). Headed Chrome uses
**display `:10`** (xRDP GNOME session). Config: `~/.agent-browser/handoff.env`.

### When to hand off

Hand off immediately for **any login**, including:

- Password / email login forms
- OAuth ("Continue with Google/GitHub/Apple")
- SSO / enterprise identity (Okta, Azure AD, etc.)
- Magic links, passkeys, WebAuthn, "check your email"
- CAPTCHA / reCAPTCHA / hCaptcha / bot checks
- 2FA, OTP, SMS code, authenticator apps
- Session expired mid-task (login wall)
- No confident next step after two snapshot attempts

Also hand off for non-login blockers:

- Payment confirmations, ambiguous UI, human-judgment prompts

Do **not**: enter credentials from chat, guess passwords, solve CAPTCHAs, or
use saved auth files without confirming with the user first.

### Login handoff (preferred for any sign-in)

Use this **before** attempting login — open headed Chrome on the login page:

```bash
agent-browser-handoff-login https://app.example.com/login --wait-url "**/dashboard" --save-auth
```

Tell the user: log in on the GNOME desktop, then reply **"done"**.

Resume and save session:

```bash
agent-browser-handoff-resume --save-auth
agent-browser snapshot -i   # confirm past login page before continuing
```

Reuse saved session on later runs:

```bash
agent-browser --state ~/.agent-browser/auth/latest-login.json open https://app.example.com/dashboard
```

If saved state fails (expired session), hand off login again — do not retry
with stale credentials.

### Mid-task handoff (CAPTCHA, 2FA, blocker after automation started)

```bash
agent-browser-handoff "CAPTCHA on checkout" --wait-url "**/confirmation"
agent-browser-handoff "Complete 2FA" --wait-text "Dashboard"
```

1. Tell the user plainly what blocked you.
2. Run handoff helper (saves state, reopens **headed** Chrome).
3. **Stop** until user replies **"done"**.
4. `agent-browser-handoff-resume` (+ `--save-auth` if login-related).
5. Verify with `snapshot -i`; hand off again if still blocked.

### Manual headed mode (if helper unavailable)

```bash
export DISPLAY=:10
URL="$(agent-browser get url)"
agent-browser state save /tmp/handoff-state.json
agent-browser close --all
agent-browser --headed --state /tmp/handoff-state.json open "$URL"
agent-browser screenshot --annotate /tmp/handoff.png
# wait for user "done", then snapshot -i and continue
```

### Optional: watch the session

```bash
agent-browser dashboard start   # http://localhost:4848
```

## Troubleshooting

| Problem | Fix |
|--------|-----|
| Ref/element not found | Re-run `agent-browser snapshot -i`; use fresh `@eN` refs |
| Chrome sandbox error | Ensure `~/.agent-browser/config.json` has `--no-sandbox`; run `agent-browser close --all` |
| Stale daemon / wrong args | `agent-browser close --all`, then retry |
| Headed window not visible | `export DISPLAY=:10`; check `~/.agent-browser/handoff.env` |
| Browser won't start | `agent-browser doctor` then `agent-browser install` |
| Need deeper docs | `agent-browser skills get core --full` |

## Specialized topics

Load when the task goes beyond normal web pages:

```bash
agent-browser skills list
agent-browser skills get electron      # VS Code, Slack, Discord, etc.
agent-browser skills get slack
agent-browser skills get dogfood       # exploratory QA / bug hunts
```
