#!/usr/bin/python

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

"""Short-term Amazon Bedrock API keys from the task's IAM role.

Stdlib-only equivalent of ``aws_bedrock_token_generator.provide_token``: a
SigV4 query-signed ``POST https://bedrock.amazonaws.com/?Action=CallWithBearerToken``
URL, base64-encoded and prefixed with ``bedrock-api-key-``. Credentials come from
the environment or the ECS container credentials endpoint, so no long-lived key
is stored anywhere.
"""

import base64
import datetime
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.parse
import urllib.request

_HOST = "bedrock.amazonaws.com"
_SERVICE = "bedrock"
_EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()

_lock = threading.Lock()
_cached_creds = None  # (access_key, secret_key, token, expiry_epoch)


def _ecs_credentials():
    rel = os.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    full = os.getenv("AWS_CONTAINER_CREDENTIALS_FULL_URI")
    if rel:
        url = f"http://169.254.170.2{rel}"
    elif full:
        url = full
    else:
        return None
    req = urllib.request.Request(url)
    token = os.getenv("AWS_CONTAINER_AUTHORIZATION_TOKEN")
    if token:
        req.add_header("Authorization", token)
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.load(resp)
    expiry = datetime.datetime.strptime(
        data["Expiration"].replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z"
    ).timestamp()
    return data["AccessKeyId"], data["SecretAccessKey"], data.get("Token"), expiry


def _credentials():
    global _cached_creds
    key = os.getenv("AWS_ACCESS_KEY_ID")
    if key:
        return key, os.environ["AWS_SECRET_ACCESS_KEY"], os.getenv("AWS_SESSION_TOKEN"), None
    with _lock:
        if _cached_creds is None or _cached_creds[3] - time.time() < 900:
            _cached_creds = _ecs_credentials()
        if _cached_creds is None:
            raise RuntimeError("No AWS credentials available for Bedrock token generation")
        return _cached_creds


def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def presign(method, host, params, service, region, creds, expires, now=None):
    """SigV4 query-string presign (same algorithm as botocore SigV4QueryAuth)."""
    access_key, secret_key, session_token = creds[0], creds[1], creds[2]
    now = now or datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    scope = f"{datestamp}/{region}/{service}/aws4_request"
    query = dict(params)
    query.update(
        {
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-Credential": f"{access_key}/{scope}",
            "X-Amz-Date": amz_date,
            "X-Amz-Expires": str(expires),
            "X-Amz-SignedHeaders": "host",
        }
    )
    if session_token:
        query["X-Amz-Security-Token"] = session_token
    canonical_qs = "&".join(
        f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(v, safe='-_.~')}"
        for k, v in sorted(query.items())
    )
    canonical_request = "\n".join(
        [method, "/", canonical_qs, f"host:{host}\n", "host", _EMPTY_SHA256]
    )
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    k = _sign(("AWS4" + secret_key).encode("utf-8"), datestamp)
    k = _sign(k, region)
    k = _sign(k, service)
    k = _sign(k, "aws4_request")
    signature = hmac.new(k, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"{host}/?{canonical_qs}&X-Amz-Signature={signature}"


def provide_token(region=None, expires=3600):
    """Return a short-term Bedrock API key signed with the current IAM credentials."""
    region = region or os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-1"
    url = presign("POST", _HOST, {"Action": "CallWithBearerToken"}, _SERVICE, region, _credentials(), expires)
    return "bedrock-api-key-" + base64.b64encode((url + "&Version=1").encode("utf-8")).decode("utf-8")
