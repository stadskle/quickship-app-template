"""
Claude (Anthropic API) AI helper.

Mirror of `ai.py`'s interface, but calls Anthropic's API directly instead
of going through Bedrock. Use this when:

- You want a Claude model that isn't published in your platform's region
  (no Frankfurt for Anthropic on Bedrock as of 2026).
- You want to avoid Bedrock's setup friction (Service Quotas, model
  access, regional inference profiles).
- The data isn't subject to AWS-region residency requirements.

API key resolution (in order):
1. `ANTHROPIC_API_KEY` env var (set automatically by the platform when
   `ai_models_enabled = true` — Lambda env var is sourced from the
   `/{prefix}/apps/{app}/anthropic_api_key` SSM SecureString).
2. Explicit `api_key=` argument to the helper functions.

If the value is the platform default `"REPLACE_ME"`, the helper raises a
clear runtime error. Set the real key with:

    aws ssm put-parameter \\
        --name /<prefix>/apps/<app>/anthropic_api_key \\
        --value 'sk-ant-...' --type SecureString --overwrite \\
        --region <region>

…then redeploy (`git push`) so Lambda picks up the new env value.

Default model is `claude-sonnet-4-7` — the latest stable mid-tier model.
Override per call with `model_id=`.
"""

from __future__ import annotations

import os

from fastapi import HTTPException


_DEFAULT_MODEL = os.environ.get("CLAUDE_DEFAULT_MODEL", "claude-sonnet-4-7")


def _resolve_api_key(explicit: str | None) -> str:
    key = explicit or os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError(
            "ANTHROPIC_API_KEY is not set. The platform should provision an SSM "
            "placeholder when ai_models_enabled = true; populate it with "
            "`aws ssm put-parameter --name /<prefix>/apps/<app>/anthropic_api_key "
            "--value sk-ant-... --type SecureString --overwrite` then redeploy."
        )
    if key == "REPLACE_ME":
        raise RuntimeError(
            "ANTHROPIC_API_KEY is the placeholder value 'REPLACE_ME'. "
            "Set the real key in SSM and redeploy — see app/lib/ai_claude.py docstring."
        )
    return key


_client = None


def _get_client(api_key: str | None = None):
    global _client
    if _client is None or api_key is not None:
        from anthropic import Anthropic

        _client = Anthropic(api_key=_resolve_api_key(api_key))
    return _client


def _call(method, **kwargs):
    """Invoke the SDK and translate provider errors into HTTP statuses."""
    from anthropic import (
        APIConnectionError,
        APITimeoutError,
        AuthenticationError,
        RateLimitError,
    )

    try:
        return method(**kwargs)
    except RateLimitError as e:
        raise HTTPException(
            status_code=429,
            detail="Anthropic rate limit hit. Try again shortly or check your usage at console.anthropic.com.",
        ) from e
    except APITimeoutError as e:
        raise HTTPException(status_code=504, detail="Anthropic API timed out.") from e
    except APIConnectionError as e:
        raise HTTPException(
            status_code=503, detail="Couldn't reach the Anthropic API."
        ) from e
    except AuthenticationError as e:
        raise HTTPException(
            status_code=500,
            detail="Anthropic API key is invalid or empty. Check the SSM secret.",
        ) from e


def generate(
    prompt: str,
    *,
    model_id: str | None = None,
    max_tokens: int = 512,
    temperature: float = 0.7,
    system: str | None = None,
    api_key: str | None = None,
) -> str:
    """Single-turn generation. Returns the assistant's text response."""
    kwargs: dict = {
        "model": model_id or _DEFAULT_MODEL,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": [{"role": "user", "content": prompt}],
    }
    if system:
        kwargs["system"] = system

    resp = _call(_get_client(api_key).messages.create, **kwargs)
    return resp.content[0].text


def chat(
    messages: list[dict],
    *,
    model_id: str | None = None,
    max_tokens: int = 512,
    temperature: float = 0.7,
    system: str | None = None,
    api_key: str | None = None,
) -> str:
    """Multi-turn chat. `messages` is a list of {role: 'user'|'assistant', content: '...'}."""
    kwargs: dict = {
        "model": model_id or _DEFAULT_MODEL,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": messages,
    }
    if system:
        kwargs["system"] = system

    resp = _call(_get_client(api_key).messages.create, **kwargs)
    return resp.content[0].text