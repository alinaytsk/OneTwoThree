"""The agenda endpoint: PUT /api/meetings/{id}/agenda.

This is where a parsed agenda is saved - the parser's own function URL can write nothing. Needs
the test database, like the rest of tests/test_api.py.
"""

from fastapi.testclient import TestClient

from tests.test_api import meeting_payload

SUGGESTION = {
    "title": "Планування спринту",
    "starts_at": "2026-10-20T15:00:00",
    "duration_minutes": 60,
    "items": [{"topic": "Демо нового пошуку", "owner": "Оля", "minutes": 15}],
    "action_items": [{"task": "Прислати макети", "owner": "Іван", "due": "2026-10-19"}],
    "language": "uk",
}


def a_meeting(client: TestClient) -> dict:
    response = client.post("/api/meetings", json=meeting_payload())
    assert response.status_code == 201, response.text
    return response.json()


def test_a_new_meeting_has_no_agenda(client: TestClient):
    meeting = a_meeting(client)
    assert meeting["agenda"] is None
    assert meeting["ai_suggestion"] is None
    assert meeting["ai_model"] is None and meeting["ai_prompt_version"] is None


def test_saving_a_parsed_agenda_keeps_what_the_model_proposed(client: TestClient):
    meeting = a_meeting(client)
    # The user kept the first topic, renamed the owner of the action item, and dropped its date.
    body = {
        "items": [{"topic": "Демо нового пошуку", "owner": "Оля", "minutes": 15}],
        "action_items": [{"task": "Прислати макети", "owner": "Іван Петренко", "due": None}],
        "ai_suggestion": SUGGESTION,
        "model": "anthropic.claude-opus-5-5",
        "prompt_version": "agenda-v1",
    }

    response = client.put(f"/api/meetings/{meeting['id']}/agenda", json=body)
    assert response.status_code == 200, response.text
    saved = response.json()

    assert saved["agenda"]["items"][0]["topic"] == "Демо нового пошуку"
    assert saved["agenda"]["action_items"][0]["owner"] == "Іван Петренко"
    assert saved["agenda"]["action_items"][0]["due"] is None
    # Both halves of the pair the metric needs: the suggestion, and what was actually kept.
    assert saved["ai_suggestion"] == SUGGESTION
    assert saved["ai_model"] == "anthropic.claude-opus-5-5"
    assert saved["ai_prompt_version"] == "agenda-v1"

    # And it is there on the next read, not only in the response to the write.
    assert client.get(f"/api/meetings/{meeting['id']}").json()["ai_prompt_version"] == "agenda-v1"


def test_a_hand_written_agenda_does_not_erase_an_earlier_suggestion(client: TestClient):
    meeting = a_meeting(client)
    client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={
            "items": [{"topic": "Демо", "owner": "Оля", "minutes": 15}],
            "action_items": [],
            "ai_suggestion": SUGGESTION,
            "model": "anthropic.claude-opus-5-5",
            "prompt_version": "agenda-v1",
        },
    )

    # A later save with no suggestion is an edit by hand; the provenance of the first one stays.
    response = client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"items": [{"topic": "Ретро", "owner": None, "minutes": None}], "action_items": []},
    )

    saved = response.json()
    assert [item["topic"] for item in saved["agenda"]["items"]] == ["Ретро"]
    assert saved["ai_suggestion"] == SUGGESTION
    assert saved["ai_prompt_version"] == "agenda-v1"


def test_an_empty_agenda_is_allowed(client: TestClient):
    meeting = a_meeting(client)
    response = client.put(f"/api/meetings/{meeting['id']}/agenda", json={"items": [], "action_items": []})
    assert response.status_code == 200
    assert response.json()["agenda"] == {"items": [], "action_items": []}


def test_a_suggestion_without_its_model_is_rejected(client: TestClient):
    meeting = a_meeting(client)
    response = client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"items": [], "action_items": [], "ai_suggestion": SUGGESTION},
    )
    # Storing what a model proposed without recording which model proposed it would make the
    # saved data useless for comparing prompt versions later.
    assert response.status_code == 422, response.text


def test_a_broken_item_is_rejected(client: TestClient):
    meeting = a_meeting(client)
    response = client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"items": [{"topic": "", "owner": "Оля", "minutes": 15}], "action_items": []},
    )
    assert response.status_code == 422


def test_another_users_meeting_cannot_be_given_an_agenda(client: TestClient):
    meeting = a_meeting(client)
    missing = "00000000-0000-0000-0000-000000000000"
    response = client.put(f"/api/meetings/{missing}/agenda", json={"items": [], "action_items": []})
    assert response.status_code == 404
    assert client.get(f"/api/meetings/{meeting['id']}").json()["agenda"] is None
