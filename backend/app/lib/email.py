"""
Outbound email helper.

Production: SES (AWS account's verified domain identity, IAM-granted by
the tinyapp module when `email_enabled = true`).
Local dev (no `EMAIL_SENDER_DOMAIN`): renders the email to stderr so the
dev sees what would have been sent. Same call site, no flag-passing.
"""

from __future__ import annotations

import os
import sys

_SENDER_DOMAIN = os.environ.get("EMAIL_SENDER_DOMAIN")
_DEFAULT_SENDER = f"noreply@{_SENDER_DOMAIN}" if _SENDER_DOMAIN else "dev@local"
_ses_client = None


def _client():
    global _ses_client
    if _ses_client is None:
        import boto3

        _ses_client = boto3.client("sesv2")
    return _ses_client


def send(
    *,
    to: str | list[str],
    subject: str,
    body_text: str,
    body_html: str | None = None,
    sender: str | None = None,
) -> None:
    """Send an email via SES, or render to stderr in local dev.

    `sender` defaults to `noreply@<your-platform-domain>`. To use a
    different from-address, pass any `<anything>@<your-platform-domain>`
    — the platform's SES identity covers the whole domain.
    """
    sender = sender or _DEFAULT_SENDER
    recipients = [to] if isinstance(to, str) else list(to)

    if _SENDER_DOMAIN:
        body: dict = {"Text": {"Data": body_text}}
        if body_html:
            body["Html"] = {"Data": body_html}
        _client().send_email(
            FromEmailAddress=sender,
            Destination={"ToAddresses": recipients},
            Content={"Simple": {"Subject": {"Data": subject}, "Body": body}},
        )
        return

    # Local-dev fallback: render to stderr.
    print("\n────── email (local dev fallback) ──────", file=sys.stderr)
    print(f"From:    {sender}", file=sys.stderr)
    print(f"To:      {', '.join(recipients)}", file=sys.stderr)
    print(f"Subject: {subject}", file=sys.stderr)
    print(file=sys.stderr)
    print(body_text, file=sys.stderr)
    if body_html:
        print("\n--- HTML alternative ---", file=sys.stderr)
        print(body_html, file=sys.stderr)
    print("─────────────────────────────────────────\n", file=sys.stderr)
