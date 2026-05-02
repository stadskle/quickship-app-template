"""
Scheduled jobs.

Each function defined at module level here can be invoked on a schedule by
adding an entry to `cron_schedules` in `infra/terraform.tfvars`:

    cron_schedules = [
        { name = "daily_report", expression = "cron(0 9 * * ? *)" },
    ]

The `name` must match a function defined below (lowercase letters / digits /
underscores). EventBridge Scheduler fires the Lambda with payload
`{"_quickship_cron": "<name>"}`; `handler.py` routes here via `dispatch()`.

Local manual invoke (no schedule, just runs the function once for testing):

    docker compose exec backend python -m app.cron <function_name>

Errors propagate. EventBridge retries per its policy (3 attempts within 1h
by default — see modules/quickship/cron.tf). Functions should be idempotent
because retries can re-run partial work.
"""

from __future__ import annotations

import logging
import sys


log = logging.getLogger(__name__)


# ---- Define your scheduled-job functions below ----------------------------
#
# Each takes no arguments and returns nothing. Use the standard `app.lib.*`
# helpers — DB, email, AI, etc. — exactly like a route handler would.
#
# Example:
#
#     def daily_report():
#         from app.lib import db, email
#         with db.connection() as conn, conn.cursor() as cur:
#             cur.execute("SELECT count(*) FROM notes")
#             count = cur.fetchone()[0]
#         email.send(
#             to="ops@example.com",
#             subject="Daily report",
#             body_text=f"{count} notes total.",
#         )


# ---- Dispatch (called by handler.py) --------------------------------------


def dispatch(name: str, event: dict, context) -> dict:
    """Look up `name` in this module's globals and call it.

    Returns a small status dict; EventBridge Scheduler ignores the return
    value but it's useful for CloudWatch logs and for the local CLI.
    """
    log.info("cron dispatch: %s", name)
    fn = globals().get(name)
    if fn is None or not callable(fn):
        log.error("no cron function named %r", name)
        return {"status": "error", "name": name, "message": "function not found"}
    fn()
    log.info("cron done: %s", name)
    return {"status": "ok", "name": name}


# ---- Local CLI: `python -m app.cron <name>` -------------------------------

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python -m app.cron <function_name>", file=sys.stderr)
        sys.exit(2)
    target = sys.argv[1]
    target_fn = globals().get(target)
    if target_fn is None or not callable(target_fn):
        print(f"No cron function named {target!r}", file=sys.stderr)
        sys.exit(1)
    target_fn()
    print(f"✓ {target}")
