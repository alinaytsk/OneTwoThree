"""Parser Lambda behind a function URL: a Cognito ID token and pasted text in, agenda JSON out.

Runs from the backend image on a different command, like the report builder does, but with no
`VpcConfig`: it needs Bedrock and the Cognito JWKS, and it needs no database. That is the whole
security story of this feature - the function the browser can reach with a 10 000-character
paste cannot read or write a single meeting. Saving goes through the API instead, which is in
the VPC and owns the data.

The function URL is `AuthType: NONE`, so AWS does not check the caller; this handler does, with
the same `verify_id_token` the API uses (`app.auth_tokens`, Lab 4). Being outside the VPC it can
fetch the JWKS itself, so no `COGNITO_JWKS` has to be passed in.

Every parse writes exactly one JSON line to CloudWatch, which Logs Insights can take apart:

  fields @timestamp, @message
  | filter @message like /agenda-parse/
  | parse @message '"cost_usd":*,' as cost
  | stats sum(cost), avg(latency_ms), count() by model, prompt_version
"""

import json
import logging
import time
from datetime import date
from typing import Any

import anthropic

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, parse_agenda
from app.auth_tokens import TokenError, verify_id_token
from app.config import settings

logger = logging.getLogger()
logger.setLevel(logging.INFO)
# Raising the root logger to INFO also turns on the HTTP client's own request logging, which puts
# a second line next to every parse ("HTTP Request: POST .../invoke") and would double the log
# volume of this group for nothing. One line per parse is the point.
# httpx2, not httpx: that is the HTTP client anthropic 1.x is built on, and the one that was
# putting "HTTP Request: POST .../invoke" next to every parse.
for noisy in (
    "httpx2",
    "httpcore2",
    "httpx",
    "httpcore",
    "anthropic",
    "botocore",
    "boto3",
    "urllib3",
):
    logging.getLogger(noisy).setLevel(logging.WARNING)

# Browsers get the CORS headers from the function URL's own configuration (infra/ai.yml), so the
# body is all this handler returns.
JSON_HEADERS = {"Content-Type": "application/json; charset=utf-8"}


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": JSON_HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }


def _error(status: int, code: str, message: str) -> dict[str, Any]:
    """One error shape for the frontend to branch on: a code, plus text it can show."""
    return _response(status, {"error": code, "detail": message})


def _bearer_token(event: dict[str, Any]) -> str | None:
    # Function URL headers arrive lower-cased, but do not rely on it.
    headers = {key.lower(): value for key, value in (event.get("headers") or {}).items()}
    authorization = headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def _body_text(event: dict[str, Any]) -> tuple[str | None, dict[str, Any] | None]:
    """The pasted text out of the request body, or an error response."""
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8", "replace")
    try:
        payload = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return None, _error(400, "bad_request", "The request body is not JSON")
    if not isinstance(payload, dict):
        return None, _error(400, "bad_request", "The request body must be a JSON object")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        return None, _error(400, "bad_request", 'Send the pasted text as {"text": "..."}')
    return text, None


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    method = (event.get("requestContext") or {}).get("http", {}).get("method", "POST")
    if method == "OPTIONS":
        # The function URL answers preflights itself; this is only a safety net.
        return _response(204, {})
    if method != "POST":
        return _error(405, "method_not_allowed", "POST a JSON body to this URL")

    token = _bearer_token(event)
    if token is None:
        return _error(401, "unauthorized", "Sign in required")
    try:
        identity = verify_id_token(token)
    except TokenError as exc:
        return _error(401, "unauthorized", str(exc))

    text, failure = _body_text(event)
    if failure is not None:
        return failure
    assert text is not None

    if len(text) > settings.parser_max_chars:
        # Checked before the model is called: this is the cheap half of the cost control.
        return _error(
            413,
            "too_long",
            f"The text is {len(text)} characters; the limit is {settings.parser_max_chars}",
        )

    started = time.monotonic()
    try:
        agenda, usage = parse_agenda(text, date.today(), settings.parser_timezone)
    except AgendaParseError as exc:
        # A failed parse is a paid-for parse: log its tokens and cost, not zeros.
        _log(identity.email, text, time.monotonic() - started, outcome=exc.code, usage=exc.usage)
        # 422: the request was fine, the text was not an agenda the model could record.
        return _error(422, exc.code, str(exc))
    except anthropic.RateLimitError as exc:
        _log(identity.email, text, time.monotonic() - started, outcome="throttled")
        return _error(429, "throttled", f"Bedrock is throttling the request: {exc}")
    except anthropic.APIStatusError as exc:
        _log(identity.email, text, time.monotonic() - started, outcome=f"api_error_{exc.status_code}")
        # 502: the model, not this function, is what failed.
        return _error(502, "model_unavailable", f"Bedrock answered {exc.status_code}: {exc}")
    except anthropic.APIConnectionError as exc:
        _log(identity.email, text, time.monotonic() - started, outcome="connection_error")
        return _error(502, "model_unavailable", f"Bedrock could not be reached: {exc}")

    latency_ms = round((time.monotonic() - started) * 1000)
    _log(identity.email, text, time.monotonic() - started, outcome="ok", usage=usage)
    return _response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": usage.model,
            "prompt_version": usage.prompt_version,
            "usage": usage.as_dict(),
            "latency_ms": latency_ms,
        },
    )


def _log(user: str, text: str, elapsed: float, outcome: str, usage: Any | None = None) -> None:
    """One JSON line per parse - the whole record of what was spent on whose behalf.

    The pasted text is never logged, only its length: it is somebody's meeting notes.
    """
    line: dict[str, Any] = {
        "event": "agenda-parse",
        "user": user,
        "outcome": outcome,
        "chars": len(text),
        "latency_ms": round(elapsed * 1000),
        "model": settings.parser_model,
        "prompt_version": PROMPT_VERSION,
        "input_tokens": 0,
        "output_tokens": 0,
        "cost_usd": 0.0,
        "price_source": settings.parser_price_source,
    }
    if usage is not None:
        line.update(
            prompt_version=usage.prompt_version,
            input_tokens=usage.input_tokens,
            output_tokens=usage.output_tokens,
            attempts=usage.attempts,
            cost_usd=round(usage.cost_usd, 6),
            price_usd_per_mtok=[
                settings.parser_price_in_per_mtok,
                settings.parser_price_out_per_mtok,
            ],
        )
    logger.info(json.dumps(line, ensure_ascii=False))
