"""Weekly meetings report: an ISO week in, CSV bytes out.

The week is always given by the caller (``"2026-W40"``); nothing in here decides what
"last week" means. That keeps the report reproducible - the same week always yields the
same rows, so a missed Monday can be rebuilt by hand months later.

Week boundaries are local to ``REPORT_TIMEZONE`` (Europe/Kyiv by default, matching the
schedule that triggers the report), not UTC: a Monday 00:30 Kyiv meeting belongs to the
week a reader would put it in.
"""

import csv
import io
import os
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.db import SessionLocal
from app.models import Meeting, User

# Both Lambdas build the same key for a week, so neither has to be told where the file went.
REPORT_PREFIX = "reports/"
REPORT_SUFFIX = ".csv"
DEFAULT_TIMEZONE = "Europe/Kyiv"
TOP_N = 5

_WEEK_RE = re.compile(r"^(\d{4})-W(\d{2})$")


class InvalidWeekError(ValueError):
    """The week string is not an ISO week, or names a week that does not exist."""


@dataclass(frozen=True)
class Totals:
    meetings: int
    hours: float


def report_timezone() -> ZoneInfo:
    return ZoneInfo(os.getenv("REPORT_TIMEZONE") or DEFAULT_TIMEZONE)


def parse_week(week: str) -> tuple[int, int]:
    """``"2026-W40"`` -> ``(2026, 40)``. Rejects anything else, week 53 of a 52-week year included."""
    match = _WEEK_RE.match(week or "")
    if not match:
        raise InvalidWeekError(f"Expected an ISO week like 2026-W40, got {week!r}")
    year, number = int(match.group(1)), int(match.group(2))
    try:
        date.fromisocalendar(year, number, 1)
    except ValueError as exc:
        raise InvalidWeekError(f"{week} is not a week that exists: {exc}") from exc
    return year, number


def format_week(day: date) -> str:
    """The ISO week a date falls in.

    Goes through isocalendar() because in late December and early January the ISO year is
    not the calendar year: 2026-01-01 is week 1 of 2026, but 2027-01-01 is week 53 of 2026.
    """
    iso = day.isocalendar()
    return f"{iso.year:04d}-W{iso.week:02d}"


def previous_week(week: str) -> str:
    year, number = parse_week(week)
    return format_week(date.fromisocalendar(year, number, 1) - timedelta(days=7))


def current_week(tz: ZoneInfo | None = None) -> str:
    return format_week(datetime.now(tz or report_timezone()).date())


def report_key(week: str) -> str:
    """S3 key for a week - deterministic, so a rerun targets the same object instead of a new one."""
    parse_week(week)
    return f"{REPORT_PREFIX}{week}{REPORT_SUFFIX}"


def week_from_key(key: str) -> str:
    """Inverse of report_key(), for the mailer subject line."""
    name = key.rsplit("/", 1)[-1]
    if not name.endswith(REPORT_SUFFIX):
        raise InvalidWeekError(f"{key} is not a report key")
    return name[: -len(REPORT_SUFFIX)]


def week_bounds(week: str, tz: ZoneInfo | None = None) -> tuple[datetime, datetime]:
    """Half-open [Monday 00:00, next Monday 00:00) in the report timezone, as aware datetimes."""
    tz = tz or report_timezone()
    year, number = parse_week(week)
    monday = date.fromisocalendar(year, number, 1)
    start = datetime.combine(monday, datetime.min.time(), tzinfo=tz)
    return start, start + timedelta(days=7)


def _meeting_hours(meeting: Meeting) -> float:
    """A meeting that ends before it starts (bad data) counts as zero, never as negative hours."""
    return max(0.0, (meeting.ends_at - meeting.starts_at).total_seconds() / 3600)


def _load_week(db: Session, start: datetime, end: datetime) -> list[Meeting]:
    """Meetings that *start* inside the window.

    One week of meetings is a small set, so the aggregation happens in Python; that keeps
    interval arithmetic out of SQL and the same code correct on any backend.
    """
    query = (
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .order_by(Meeting.starts_at, Meeting.id)
    )
    return list(db.scalars(query))


def _totals(meetings: list[Meeting]) -> Totals:
    return Totals(len(meetings), round(sum(_meeting_hours(m) for m in meetings), 2))


def _owner_labels(db: Session, meetings: list[Meeting]) -> dict[object, tuple[str, str]]:
    owner_ids = {m.owner_id for m in meetings if m.owner_id is not None}
    if not owner_ids:
        return {}
    users = db.scalars(select(User).where(User.id.in_(owner_ids))).all()
    return {user.id: (user.name or user.email, user.email) for user in users}


def _rank(buckets: dict[tuple[str, str], list[float]]) -> list[tuple[str, str, int, float]]:
    rows = [(name, email, len(hours), round(sum(hours), 2)) for (name, email), hours in buckets.items()]
    # Busiest first; the name breaks ties so a given week always serialises identically.
    return sorted(rows, key=lambda row: (-row[3], -row[2], row[0]))


def _by_person(
    meetings: list[Meeting], owners: dict[object, tuple[str, str]]
) -> dict[str, list[tuple[str, str, int, float]]]:
    """The schema has no organiser/member tables, so the organiser is the owner of the meeting
    and the members are its participants. Both breakdowns are reported."""
    organisers: dict[tuple[str, str], list[float]] = {}
    members: dict[tuple[str, str], list[float]] = {}
    for meeting in meetings:
        hours = _meeting_hours(meeting)
        organisers.setdefault(owners.get(meeting.owner_id, ("(unassigned)", "")), []).append(hours)
        for participant in meeting.participants:
            members.setdefault((participant.name, participant.email), []).append(hours)
    return {"organisers": _rank(organisers), "members": _rank(members)}


def _delta(current: float, previous: float) -> float:
    return round(current - previous, 2)


def build_weekly_report(week: str, db: Session | None = None) -> bytes:
    """CSV for ``week``, with the previous week beside it for comparison.

    ``db`` is for tests and for callers that already hold a session; by default a session is
    opened against the configured database and closed again.
    """
    if db is not None:
        return _build(week, db)
    with SessionLocal() as session:
        return _build(week, session)


def _build(week: str, db: Session) -> bytes:
    tz = report_timezone()
    prev = previous_week(week)
    start, end = week_bounds(week, tz)
    prev_start, prev_end = week_bounds(prev, tz)

    meetings = _load_week(db, start, end)
    now = _totals(meetings)
    before = _totals(_load_week(db, prev_start, prev_end))
    people = _by_person(meetings, _owner_labels(db, meetings))

    buffer = io.StringIO(newline="")
    out = csv.writer(buffer)

    out.writerow(["report", "weekly meetings"])
    out.writerow(["week", week])
    out.writerow(["period_start", start.isoformat()])
    out.writerow(["period_end", end.isoformat()])
    out.writerow(["timezone", str(tz)])
    out.writerow(["previous_week", prev])
    out.writerow(["generated_at", datetime.now(tz).isoformat(timespec="seconds")])

    out.writerow([])
    out.writerow(["section", "totals"])
    out.writerow(["metric", week, prev, "delta"])
    out.writerow(["meetings", now.meetings, before.meetings, _delta(now.meetings, before.meetings)])
    out.writerow(
        ["hours", f"{now.hours:.2f}", f"{before.hours:.2f}", f"{_delta(now.hours, before.hours):.2f}"]
    )

    out.writerow([])
    out.writerow(["section", f"top {TOP_N} longest meetings"])
    out.writerow(["rank", "title", "starts_at", "duration_hours", "participants"])
    longest = sorted(meetings, key=lambda m: (-_meeting_hours(m), m.starts_at, m.title))[:TOP_N]
    for rank, meeting in enumerate(longest, start=1):
        out.writerow(
            [
                rank,
                meeting.title,
                meeting.starts_at.astimezone(tz).isoformat(timespec="minutes"),
                f"{_meeting_hours(meeting):.2f}",
                len(meeting.participants),
            ]
        )
    if not longest:
        out.writerow(["", "(no meetings this week)", "", "", ""])

    for key, heading in (("organisers", "by organiser (meeting owner)"), ("members", "by participant")):
        out.writerow([])
        out.writerow(["section", heading])
        out.writerow(["name", "email", "meetings", "hours"])
        for name, email, count, hours in people[key]:
            out.writerow([name, email, count, f"{hours:.2f}"])
        if not people[key]:
            out.writerow(["(nobody)", "", 0, "0.00"])

    # utf-8-sig: the file is opened in Excel straight from an email, which needs the BOM to
    # read UTF-8 names correctly.
    return buffer.getvalue().encode("utf-8-sig")
