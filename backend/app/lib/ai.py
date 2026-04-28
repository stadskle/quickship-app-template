"""
Bedrock AI helper.

No local fallback — Bedrock at dev volumes costs cents and there's no
useful local emulator. The container needs AWS credentials (mounted from
the host's `~/.aws` in docker-compose.yml).

The default model is `amazon.nova-lite-v1:0` (the only model the platform
publishes for eu-central-1 by default — Anthropic Claude isn't yet in
Frankfurt). To use a different model, the platform operator updates
`bedrock_models` in the bootstrap; per-app code passes a different
`model_id` to these functions.

Uses Bedrock's `Converse` API which is provider-agnostic — same call
shape works for Nova, Claude, Titan, Llama, etc.
"""

from __future__ import annotations

import os

_bedrock_client = None
_DEFAULT_MODEL = os.environ.get("AI_DEFAULT_MODEL", "amazon.nova-lite-v1:0")


def _client():
    global _bedrock_client
    if _bedrock_client is None:
        import boto3

        _bedrock_client = boto3.client("bedrock-runtime")
    return _bedrock_client


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

    resp = _client().converse(**kwargs)
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

    resp = _client().converse(**kwargs)
    return resp["output"]["message"]["content"][0]["text"]
