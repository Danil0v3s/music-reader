"""Sending the account emails (verify an address, reset a password).

Uses SMTP when OMR_SMTP_HOST is set (any provider: Postmark, Resend, SES, a Gmail app password…);
otherwise prints the message to the log, which is enough on a development server. `outbox` keeps the
last messages for tests.
"""

from __future__ import annotations

import os
import smtplib
import ssl
from collections import deque
from email.message import EmailMessage

SMTP_HOST = os.environ.get("OMR_SMTP_HOST") or None
SMTP_PORT = int(os.environ.get("OMR_SMTP_PORT", "587"))
SMTP_USER = os.environ.get("OMR_SMTP_USER") or None
SMTP_PASSWORD = os.environ.get("OMR_SMTP_PASSWORD") or None
SENDER = os.environ.get("OMR_MAIL_FROM", "Music Reader <no-reply@localhost>")

outbox: deque[EmailMessage] = deque(maxlen=50)


def send(to: str, subject: str, text: str) -> None:
    msg = EmailMessage()
    msg["From"] = SENDER
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(text)
    outbox.append(msg)
    if not SMTP_HOST:
        print(f"[mail to {to}] {subject}\n{text}", flush=True)
        return
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as s:
            s.starttls(context=ssl.create_default_context())
            if SMTP_USER:
                s.login(SMTP_USER, SMTP_PASSWORD or "")
            s.send_message(msg)
    except (OSError, smtplib.SMTPException) as e:
        print(f"[mail to {to}] couldn't send: {e}", flush=True)
