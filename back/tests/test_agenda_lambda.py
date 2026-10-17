"""The parser Lambda: who it lets in, what it refuses, and the one line it logs per parse.

Neither Bedrock nor Cognito is reached: `verify_id_token` and `parse_agenda` are replaced. What
is actually asserted here is the handler's contract with the browser (status codes and error
codes the UI branches on) and with CloudWatch (one JSON line, with the cost, and never the
pasted text).
"""

import json
from datetime import date, datetime
from typing import Any

import anthropic
import httpx2
import pytest

from app.ai import agenda_lambda as handler_module
from app.ai.agenda import AgendaParseError, ParsedAgenda, Usage
from app.ai.agenda_lambda import handler
from app.auth_tokens import Identity, TokenError
from app.config import settings

IDENTITY = Identity(sub="sub-anna", email="anna@example.com", name="Anna")

AGENDA = ParsedAgenda(
    title="Планування спринту",
    starts_at=datetime(2026, 10, 20, 15, 0),
    duration_minutes=60,
    items=[{"topic": "Демо", "owner": "Оля", "minutes": 15}],
    action_items=[{"task": "Макети", "owner": "Іван", "due": date(2026, 10, 19)}],
    language="uk",
)
USAGE = Usage(
    model="anthropic.claude-opus-5-5",
    prompt_version="agenda-v1",
    input_tokens=912,
    output_tokens=133,
    attempts=1,
)


def event(text: str | Any = "Планування спринту", token: str | None = "id-token", **overrides) -> dict:
    body = overrides.pop("body", json.dumps({"text": text}) if text is not None else None)
    return {
        "requestContext": {"http": {"method": overrides.pop("method", "POST")}},
        "headers": {"authorization": f"Bearer {token}"} if token else {},
        "body": body,
        "isBase64Encoded": False,
        **overrides,
    }


def body_of(response: dict) -> dict:
    return json.loads(response["body"])


@pytest.fixture(autouse=True)
def signed_in(monkeypatch: pytest.MonkeyPatch):
    """Every test starts with a valid token; the auth tests override this."""
    monkeypatch.setattr(handler_module, "verify_id_token", lambda token: IDENTITY)


@pytest.fixture
def parses(monkeypatch: pytest.MonkeyPatch):
    """Replaces parse_agenda with a recorder returning (or raising) what the test wants."""
    calls: list[tuple] = []

    def install(result: Any) -> list[tuple]:
        def fake(text: str, today: date, tz: str):
            calls.append((text, today, tz))
            if isinstance(result, Exception):
                raise result
            return result

        monkeypatch.setattr(handler_module, "parse_agenda", fake)
        return calls

    return install


def log_lines(caplog: pytest.LogCaptureFixture) -> list[dict]:
    lines = []
    for record in caplog.records:
        try:
            parsed = json.loads(record.getMessage())
        except json.JSONDecodeError:
            continue
        if parsed.get("event") == "agenda-parse":
            lines.append(parsed)
    return lines


# --- the gate --------------------------------------------------------------------------------


def test_a_missing_token_is_401(parses):
    parses((AGENDA, USAGE))
    response = handler(event(token=None), None)
    assert response["statusCode"] == 401
    assert body_of(response)["error"] == "unauthorized"


def test_a_rejected_token_is_401(monkeypatch: pytest.MonkeyPatch, parses):
    called = parses((AGENDA, USAGE))

    def reject(token: str):
        raise TokenError("Invalid token: expired")

    monkeypatch.setattr(handler_module, "verify_id_token", reject)

    response = handler(event(), None)

    assert response["statusCode"] == 401
    assert "expired" in body_of(response)["detail"]
    # The model is never called for a caller we could not identify.
    assert called == []


def test_only_post_is_answered(parses):
    parses((AGENDA, USAGE))
    assert handler(event(method="GET"), None)["statusCode"] == 405
    # A preflight the function URL did not already answer still gets a valid response.
    assert handler(event(method="OPTIONS"), None)["statusCode"] == 204


@pytest.mark.parametrize(
    "bad_body",
    ["not json at all", json.dumps({"text": "   "}), json.dumps({}), json.dumps(["text"])],
    ids=["not-json", "blank-text", "no-text", "not-an-object"],
)
def test_a_body_without_text_is_400(parses, bad_body: str):
    called = parses((AGENDA, USAGE))
    response = handler(event(body=bad_body, text=None), None)
    assert response["statusCode"] == 400
    assert body_of(response)["error"] == "bad_request"
    assert called == []


def test_text_over_the_limit_is_413_before_the_model_is_called(parses, caplog):
    called = parses((AGENDA, USAGE))
    too_long = "х" * (settings.parser_max_chars + 1)

    with caplog.at_level("INFO"):
        response = handler(event(too_long), None)

    assert response["statusCode"] == 413
    assert body_of(response)["error"] == "too_long"
    # The whole point of the limit: nothing is spent on a paste this size.
    assert called == []
    assert log_lines(caplog) == []


# --- the happy path --------------------------------------------------------------------------


def test_a_parse_returns_the_agenda_with_its_model_and_usage(parses, caplog):
    called = parses((AGENDA, USAGE))

    with caplog.at_level("INFO"):
        response = handler(event("Планування спринту у вівторок 15:00"), None)

    assert response["statusCode"] == 200
    body = body_of(response)
    assert body["agenda"]["title"] == "Планування спринту"
    assert body["agenda"]["action_items"][0]["due"] == "2026-10-19"
    assert body["model"] == "anthropic.claude-opus-5-5"
    assert body["prompt_version"] == "agenda-v1"
    assert body["usage"]["input_tokens"] == 912
    assert body["latency_ms"] >= 0
    # Relative dates are resolved against the day the request arrives, in the configured zone.
    assert called[0][1] == date.today() and called[0][2] == settings.parser_timezone


def test_one_json_line_per_parse_carries_the_cost_but_not_the_paste(parses, caplog):
    parses((AGENDA, USAGE))
    paste = "Планування спринту: демо нового пошуку, Оля"

    with caplog.at_level("INFO"):
        handler(event(paste), None)

    (line,) = log_lines(caplog)
    assert line["user"] == "anna@example.com"
    assert line["outcome"] == "ok"
    assert line["model"] == "anthropic.claude-opus-5-5"
    assert line["prompt_version"] == "agenda-v1"
    assert (line["input_tokens"], line["output_tokens"], line["attempts"]) == (912, 133, 1)
    assert line["cost_usd"] > 0
    assert line["latency_ms"] >= 0
    assert line["chars"] == len(paste)
    # Somebody's meeting notes do not belong in a log group.
    assert paste not in json.dumps(line, ensure_ascii=False)


# --- the failures the UI has to tell apart ---------------------------------------------------


def test_no_agenda_is_422_with_its_code(parses, caplog):
    parses(
        AgendaParseError(
            "The text does not look like an agenda",
            "no_agenda",
            # What that answer cost anyway.
            Usage(
                model="anthropic.claude-opus-5-5",
                prompt_version="agenda-v1",
                input_tokens=1646,
                output_tokens=12,
                attempts=1,
            ),
        )
    )

    with caplog.at_level("INFO"):
        response = handler(event("молоко, хліб, кава"), None)

    assert response["statusCode"] == 422
    assert body_of(response)["error"] == "no_agenda"
    # A parse that produced nothing is still logged, so failures are countable - and it is
    # logged with what it cost, because the model was called and billed all the same.
    line = log_lines(caplog)[0]
    assert line["outcome"] == "no_agenda"
    assert (line["input_tokens"], line["output_tokens"]) == (1646, 12)
    assert line["cost_usd"] > 0


def test_an_answer_that_never_validates_is_422_invalid_output(parses):
    parses(AgendaParseError("did not validate twice", "invalid_output"))
    response = handler(event(), None)
    assert response["statusCode"] == 422
    assert body_of(response)["error"] == "invalid_output"


def test_throttling_is_passed_through_as_429(parses, caplog):
    throttled = anthropic.RateLimitError(
        "Too many requests",
        response=httpx2.Response(429, request=httpx2.Request("POST", "https://bedrock/")),
        body=None,
    )
    parses(throttled)

    with caplog.at_level("INFO"):
        response = handler(event(), None)

    assert response["statusCode"] == 429
    assert body_of(response)["error"] == "throttled"
    assert log_lines(caplog)[0]["outcome"] == "throttled"


def test_a_bedrock_outage_is_502_not_500(parses, caplog):
    down = anthropic.InternalServerError(
        "Service unavailable",
        response=httpx2.Response(503, request=httpx2.Request("POST", "https://bedrock/")),
        body=None,
    )
    parses(down)

    with caplog.at_level("INFO"):
        response = handler(event(), None)

    assert response["statusCode"] == 502
    assert body_of(response)["error"] == "model_unavailable"
    assert log_lines(caplog)[0]["outcome"] == "api_error_503"


def test_a_network_failure_is_502_as_well(parses):
    unreachable = anthropic.APIConnectionError(request=httpx2.Request("POST", "https://bedrock/"))
    parses(unreachable)

    response = handler(event(), None)

    assert response["statusCode"] == 502
    assert body_of(response)["error"] == "model_unavailable"
