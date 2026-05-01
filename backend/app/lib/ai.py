"""
Bedrock AI helper.

No local fallback — Bedrock at dev volumes costs cents and there's no
useful local emulator. The container needs AWS credentials (mounted from
the host's `~/.aws` in docker-compose.yml).

The default model is `<geo>.amazon.nova-lite-v1:0` where `<geo>` is the
region's inference-profile prefix (`eu` in eu-*, `us` in us-*, etc.).
AWS Bedrock requires regional inference-profile IDs for on-demand
invocation; the bare foundation-model ID returns ValidationException
"Invocation of model ID ... with on-demand throughput isn't supported."

To use a different model, the platform operator updates `bedrock_models`
in the bootstrap; per-app code passes a different `model_id` to these
functions (full inference-profile ID, e.g. `eu.amazon.nova-lite-v1:0`).

Uses Bedrock's `Converse` API which is provider-agnostic — same call
shape works for Nova, Claude, Titan, Llama, etc.
"""

from __future__ import annotations

import os

from fastapi import HTTPException


def _default_model() -> str:
    """Compose the regional inference-profile ID for the platform default."""
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or ""
    if region.startswith("eu-"):
        prefix = "eu"
    elif region.startswith("us-"):
        prefix = "us"
    elif region.startswith("ap-"):
        prefix = "apac"
    else:
        prefix = ""
    base = "amazon.nova-lite-v1:0"
    return f"{prefix}.{base}" if prefix else base


_bedrock_client = None
_DEFAULT_MODEL = os.environ.get("AI_DEFAULT_MODEL", _default_model())


def _client():
    global _bedrock_client
    if _bedrock_client is None:
        import boto3

        _bedrock_client = boto3.client("bedrock-runtime")
    return _bedrock_client


def _converse(**kwargs):
    """Call Bedrock Converse and translate AWS error codes into useful HTTP errors.

    Without this, every quota/availability hiccup surfaces as a generic 500
    in the frontend. Map the two we expect to see in practice — Throttling
    and ServiceUnavailable — to 429/503 with a human-readable detail.
    """
    from botocore.exceptions import ClientError

    try:
        return _client().converse(**kwargs)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code == "ThrottlingException":
            raise HTTPException(
                status_code=429,
                detail="AI rate limit hit. If this persists, check the model's token-per-day quota in the AWS Service Quotas console.",
            ) from e
        if code == "ServiceUnavailableException":
            raise HTTPException(
                status_code=503,
                detail="AI service is temporarily unavailable. Retry shortly.",
            ) from e
        raise


def generate(
    prompt: str,
    *,
    model_id: str | None = None,
    max_tokens: int = 512,
    temperature: float = 0.7,
    system: str | None = None,
) -> str:
    """Single-turn generation. Returns the assistant's text response."""
    messages = [{"role": "user", "content": [{"text": prompt}]}]
    kwargs: dict = {
        "modelId": model_id or _DEFAULT_MODEL,
        "messages": messages,
        "inferenceConfig": {"maxTokens": max_tokens, "temperature": temperature},
    }
    if system:
        kwargs["system"] = [{"text": system}]

    resp = _converse(**kwargs)
    return resp["output"]["message"]["content"][0]["text"]


def chat(
    messages: list[dict],
    *,
    model_id: str | None = None,
    max_tokens: int = 512,
    temperature: float = 0.7,
    system: str | None = None,
) -> str:
    """Multi-turn chat. `messages` is a list of {role: 'user'|'assistant', content: '...'}.

    Bedrock Converse expects content as a list of blocks; this helper
    accepts the simpler {role, content: str} shape and adapts it.
    """
    converse_messages = [
        {
            "role": m["role"],
            "content": [{"text": m["content"]}]
            if isinstance(m["content"], str)
            else m["content"],
        }
        for m in messages
    ]
    kwargs: dict = {
        "modelId": model_id or _DEFAULT_MODEL,
        "messages": converse_messages,
        "inferenceConfig": {"maxTokens": max_tokens, "temperature": temperature},
    }
    if system:
        kwargs["system"] = [{"text": system}]

    resp = _converse(**kwargs)
    return resp["output"]["message"]["content"][0]["text"]
