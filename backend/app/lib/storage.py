"""
S3 storage helper with local-directory fallback.

Production: S3 bucket whose name is in `STORAGE_BUCKET`.
Local dev (env var unset): writes/reads to/from `./uploads/` in the
backend container's working dir, which is bind-mounted to the host.
"""

from __future__ import annotations

import os
from pathlib import Path

import boto3

_BUCKET = os.environ.get("STORAGE_BUCKET")
_LOCAL_DIR = Path("./uploads")
_s3_client = None


def _client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _local_path(key: str) -> Path:
    path = _LOCAL_DIR / key
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def upload(key: str, data: bytes, content_type: str | None = None) -> None:
    """Store `data` at `key`."""
    if _BUCKET:
        kwargs = {"Bucket": _BUCKET, "Key": key, "Body": data}
        if content_type:
            kwargs["ContentType"] = content_type
        _client().put_object(**kwargs)
    else:
        _local_path(key).write_bytes(data)


def download(key: str) -> bytes:
    """Retrieve the bytes at `key`. Raises if missing."""
    if _BUCKET:
        return _client().get_object(Bucket=_BUCKET, Key=key)["Body"].read()
    path = _local_path(key)
    if not path.is_file():
        raise FileNotFoundError(f"No object at key {key!r}")
    return path.read_bytes()


def delete(key: str) -> None:
    """Delete the object at `key`. No error if it doesn't exist."""
    if _BUCKET:
        _client().delete_object(Bucket=_BUCKET, Key=key)
    else:
        _local_path(key).unlink(missing_ok=True)


def exists(key: str) -> bool:
    """True if the object exists."""
    if _BUCKET:
        try:
            _client().head_object(Bucket=_BUCKET, Key=key)
            return True
        except _client().exceptions.ClientError:
            return False
    return _local_path(key).is_file()


def presigned_url(key: str, expires_in: int = 3600) -> str:
    """A URL the browser can hit directly to download the object.

    Locally, returns a `file://` URL pointing at the on-disk path. App code
    that builds links should treat that as a hint, not a real public URL.
    """
    if _BUCKET:
        return _client().generate_presigned_url(
            "get_object",
            Params={"Bucket": _BUCKET, "Key": key},
            ExpiresIn=expires_in,
        )
    return f"file://{_local_path(key).resolve()}"


def presigned_upload_url(
    key: str, expires_in: int = 3600, content_type: str | None = None
) -> str:
    """A URL the browser can PUT to directly to upload the object.

    Locally there's no meaningful equivalent; the function raises so the
    caller knows to use the `upload(...)` API instead during dev.
    """
    if not _BUCKET:
        raise NotImplementedError(
            "Presigned upload URLs aren't supported in local dev. "
            "Have the frontend POST to a backend route that calls storage.upload(...)."
        )
    params = {"Bucket": _BUCKET, "Key": key}
    if content_type:
        params["ContentType"] = content_type
    return _client().generate_presigned_url(
        "put_object", Params=params, ExpiresIn=expires_in
    )
