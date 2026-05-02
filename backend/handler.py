"""
Lambda entrypoint shim.

Routes invocations:
- HTTP events (Function URL / API Gateway) → Mangum/FastAPI app
- Scheduled-job events `{"_quickship_cron": "<name>"}` → app.cron.dispatch

The platform's quickship module configures Lambda with
`handler = "handler.handler"`, so this module-level `handler` callable
is the entrypoint.
"""

from app.main import handler as _http_handler


def handler(event, context):
    if isinstance(event, dict) and "_quickship_cron" in event:
        from app.cron import dispatch

        return dispatch(event["_quickship_cron"], event, context)
    return _http_handler(event, context)


__all__ = ["handler"]
