"""Weekly report tests: `make test-back` runs them against the compose database, no AWS.

The report is handed an explicit session (the same meetings_test database the other tests
use), so nothing here touches app.db.SessionLocal or the deployed Aurora cluster.
"""

import csv
import io
from collections.abc import Iterator
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.models import Meeting, Participant, User
from app.reports.weekly import (
    InvalidWeekError,
    build_weekly_report,
    format_week,
    previous_week,
    report_key,
    week_bounds,
    week_from_key,
)
from tests.conftest import TestingSession, engine

KYIV = ZoneInfo("Europe/Kyiv")
WEEK = "2026-W40"  # Mon 2026-09-28 .. Sun 2026-10-04
PREV = "2026-W39"  # Mon 2026-09-21 .. Sun 2026-09-27


@pytest.fixture
def db() -> Iterator[Session]:
    with TestingSession() as session:
        yield session
    with engine.begin() as conn:
        conn.execute(text("TRUNCATE meeting_participants, meetings, participants, users"))


def at(day: str, hour: int) -> datetime:
    """A Kyiv-local wall-clock time, as the app stores it (timezone-aware)."""
    return datetime.fromisoformat(day).replace(hour=hour, tzinfo=KYIV)


def add_meeting(
    db: Session,
    title: str,
    start: datetime,
    hours: float,
    owner: User | None = None,
    participants: list[Participant] | None = None,
) -> Meeting:
    meeting = Meeting(
        title=title,
        starts_at=start,
        ends_at=start + timedelta(hours=hours),
        owner_id=owner.id if owner else None,
        participants=participants or [],
    )
    db.add(meeting)
    db.commit()
    return meeting


def sections(csv_bytes: bytes) -> dict[str, list[list[str]]]:
    """Split the sectioned CSV into {section heading: rows after its header row}."""
    rows = list(csv.reader(io.StringIO(csv_bytes.decode("utf-8-sig"))))
    out: dict[str, list[list[str]]] = {"head": []}
    current = "head"
    for row in rows:
        if row and row[0] == "section":
            current = row[1]
            out[current] = []
        elif row:
            out[current].append(row)
    return out


def head(csv_bytes: bytes) -> dict[str, str]:
    return {row[0]: row[1] for row in sections(csv_bytes)["head"]}


# --- week arithmetic (no database) ------------------------------------------------------


def test_report_key_is_deterministic() -> None:
    assert report_key(WEEK) == "reports/2026-W40.csv"
    assert report_key(WEEK) == report_key(WEEK)
    assert week_from_key(report_key(WEEK)) == WEEK


@pytest.mark.parametrize("bad", ["", "2026-40", "26-W40", "2026-W00", "2026-W54", "../etc/passwd"])
def test_report_key_rejects_non_weeks(bad: str) -> None:
    with pytest.raises(InvalidWeekError):
        report_key(bad)


def test_previous_week_crosses_the_year_boundary() -> None:
    assert previous_week(WEEK) == PREV
    # 2026 has 53 ISO weeks, so week 1 of 2027 follows 2026-W53, not 2026-W52.
    assert previous_week("2027-W01") == "2026-W53"
    assert format_week(datetime(2027, 1, 1).date()) == "2026-W53"


def test_week_bounds_are_local_monday_to_monday() -> None:
    start, end = week_bounds(WEEK, KYIV)
    assert (start.isoformat(), end.isoformat()) == (
        "2026-09-28T00:00:00+03:00",
        "2026-10-05T00:00:00+03:00",
    )
    assert end - start == timedelta(days=7)


# --- the report itself ------------------------------------------------------------------


def test_counts_hours_and_delta_against_the_previous_week(db: Session) -> None:
    add_meeting(db, "Standup", at("2026-09-28", 9), 0.5)
    add_meeting(db, "Review", at("2026-10-02", 14), 2)
    add_meeting(db, "Last week retro", at("2026-09-24", 10), 1)

    totals = sections(build_weekly_report(WEEK, db))["totals"]
    assert totals[0] == ["metric", WEEK, PREV, "delta"]
    assert totals[1] == ["meetings", "2", "1", "1"]
    assert totals[2] == ["hours", "2.50", "1.00", "1.50"]


def test_week_boundaries_are_half_open(db: Session) -> None:
    add_meeting(db, "Monday 00:00 in", at("2026-09-28", 0), 1)
    add_meeting(db, "Next Monday 00:00 out", at("2026-10-05", 0), 1)
    add_meeting(db, "Sunday 23:00 in", at("2026-10-04", 23), 1)

    top = sections(build_weekly_report(WEEK, db))["top 5 longest meetings"]
    titles = [row[1] for row in top[1:]]  # [0] is the column header row
    assert "Next Monday 00:00 out" not in titles
    assert sorted(titles) == ["Monday 00:00 in", "Sunday 23:00 in"]


def test_top_five_longest_with_participant_counts(db: Session) -> None:
    people = [Participant(name=f"P{i}", email=f"p{i}@example.com") for i in range(3)]
    db.add_all(people)
    db.commit()

    for index, hours in enumerate([1, 6, 2, 5, 3, 4]):
        add_meeting(db, f"M{hours}h", at("2026-09-28", 8) + timedelta(days=index), hours, None, people[:2])

    top = sections(build_weekly_report(WEEK, db))["top 5 longest meetings"]
    assert top[0] == ["rank", "title", "starts_at", "duration_hours", "participants"]
    # Longest first, and only five rows however many meetings there were.
    assert [row[1] for row in top[1:]] == ["M6h", "M5h", "M4h", "M3h", "M2h"]
    assert [row[3] for row in top[1:]] == ["6.00", "5.00", "4.00", "3.00", "2.00"]
    assert top[1][4] == "2"


def test_breakdown_by_organiser_and_participant(db: Session) -> None:
    owner = User(cognito_sub="sub-1", email="olena@example.com", name="Olena")
    anna = Participant(name="Anna", email="anna@example.com")
    oleh = Participant(name="Oleh", email="oleh@example.com")
    db.add_all([owner, anna, oleh])
    db.commit()

    add_meeting(db, "Planning", at("2026-09-28", 9), 2, owner, [anna, oleh])
    add_meeting(db, "One-on-one", at("2026-09-29", 9), 1, owner, [anna])

    report = sections(build_weekly_report(WEEK, db))
    assert report["by organiser (meeting owner)"][1:] == [["Olena", "olena@example.com", "2", "3.00"]]
    assert report["by participant"][1:] == [
        ["Anna", "anna@example.com", "2", "3.00"],
        ["Oleh", "oleh@example.com", "1", "2.00"],
    ]


def test_meetings_without_an_owner_are_reported_as_unassigned(db: Session) -> None:
    add_meeting(db, "Legacy meeting", at("2026-09-30", 11), 1)

    organisers = sections(build_weekly_report(WEEK, db))["by organiser (meeting owner)"]
    assert organisers[1] == ["(unassigned)", "", "1", "1.00"]


def test_empty_week_still_produces_a_readable_report(db: Session) -> None:
    report = build_weekly_report(WEEK, db)

    assert head(report)["week"] == WEEK
    assert head(report)["previous_week"] == PREV
    assert head(report)["timezone"] == "Europe/Kyiv"
    parsed = sections(report)
    assert parsed["totals"][1] == ["meetings", "0", "0", "0"]
    assert parsed["top 5 longest meetings"][1][1] == "(no meetings this week)"
    assert parsed["by participant"][1][0] == "(nobody)"


def test_report_is_csv_with_a_bom_for_excel(db: Session) -> None:
    report = build_weekly_report(WEEK, db)

    assert report.startswith(b"\xef\xbb\xbf")
    assert b"\r\n" in report
