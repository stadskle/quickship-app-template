"""
Secrets helper.

Per-app secrets are declared in `infra/terraform.tfvars` under `secret_names`.
The platform creates an SSM SecureString placeholder per name and injects the
current value into the Lambda as an env var `<NAME_UPPERCASE>` at deploy time.

App code calls `secrets.get("stripe_api_key")` and gets the value back, with
the same code path locally and in production:

- Locally: set the env var (shell export, `.env`, or docker-compose `environment:`).
- Production: the platform reads SSM at apply time and injects the value.

Rotation: update the SSM value (`aws ssm put-parameter --overwrite ...`) and
re-deploy so Terraform re-reads it and pushes the new value to Lambda env.
"""

from __future__ import annotations

import os

_PLACEHOLDER = "REPLACE_ME"

# Names the platform already injects as Lambda env vars for built-in
# capabilities. Reserving them here prevents `secret_names` collisions
# from silently shadowing platform-managed values (e.g. someone adding
# "database_url" to secret_names would otherwise overwrite the
# platform-injected DATABASE_URL).
_RESERVED_NAMES = frozenset({
    "database_url",
    "storage_bucket",
    "email_sender_domain",
    "tinyapp_name",
    "aws_region",
    "aws_default_region",
})


def get(name: str) -> str:
    """Return the value of secret `name`. Raises if unset or still a placeholder."""
    if name.lower() in _RESERVED_NAMES:
        raise RuntimeError(
            f"Secret name '{name}' is reserved by the platform "
            f"(injected as a Lambda env var by capability flags). "
            f"Pick a different name like '{name}_secret' or '{name}_token'."
        )

    env_key = name.upper()
    value = os.environ.get(env_key)

    if value is None:
        raise RuntimeError(
            f"Secret '{name}' is not set. "
            f"In production: add '{name}' to `secret_names` in infra/terraform.tfvars and run /deploy. "
            f"Locally: set env var {env_key} (e.g. in your shell or docker-compose.yml)."
        )

    if value == _PLACEHOLDER:
        raise RuntimeError(
            f"Secret '{name}' has the placeholder value. "
            f"Set the real value with: "
            f"aws ssm put-parameter --name /<prefix>/apps/<app>/{name} "
            f"--value '...' --type SecureString --overwrite --region <region>, "
            f"then run /deploy again so Terraform re-reads it."
        )

    return value
