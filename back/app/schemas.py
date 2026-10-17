from datetime import date, datetime
from uuid import UUID

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    HttpUrl,
    field_validator,
    model_validator,
)


def _blank_to_none(value: object) -> object:
    if isinstance(value, str) and not value.strip():
        return None
    return value


class ParticipantCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    name: str = Field(min_length=1, max_length=120)
    email: EmailStr

    @field_validator("email")
    @classmethod
    def lowercase_email(cls, value: str) -> str:
        return value.lower()


class ParticipantRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    email: str


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    email: str
    name: str | None


class UserUpdate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    name: str | None = Field(default=None, max_length=120)

    @field_validator("name", mode="before")
    @classmethod
    def blank_to_none(cls, value: object) -> object:
        return _blank_to_none(value)


class MeetingCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    title: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=5000)
    call_link: HttpUrl | None = None
    place: str | None = Field(default=None, max_length=255)
    starts_at: AwareDatetime
    ends_at: AwareDatetime
    participant_ids: list[UUID] = []

    @field_validator("description", "call_link", "place", mode="before")
    @classmethod
    def blank_to_none(cls, value: object) -> object:
        return _blank_to_none(value)

    @model_validator(mode="after")
    def require_call_link_or_place(self) -> "MeetingCreate":
        if self.call_link is None and self.place is None:
            raise ValueError("Provide a call link, a place, or both")
        return self

    @model_validator(mode="after")
    def ends_after_start(self) -> "MeetingCreate":
        if self.ends_at <= self.starts_at:
            raise ValueError("The meeting must end after it starts")
        return self


class AgendaItem(BaseModel):
    """One point on the agenda, as the user saved it."""

    model_config = ConfigDict(str_strip_whitespace=True)

    topic: str = Field(min_length=1, max_length=300)
    owner: str | None = Field(default=None, max_length=120)
    minutes: int | None = Field(default=None, ge=1, le=600)

    @field_validator("owner", mode="before")
    @classmethod
    def blank_to_none(cls, value: object) -> object:
        return _blank_to_none(value)


class AgendaActionItem(BaseModel):
    """Something to do after the meeting."""

    model_config = ConfigDict(str_strip_whitespace=True)

    task: str = Field(min_length=1, max_length=500)
    owner: str | None = Field(default=None, max_length=120)
    due: date | None = None

    @field_validator("owner", "due", mode="before")
    @classmethod
    def blank_to_none(cls, value: object) -> object:
        return _blank_to_none(value)


class AgendaBody(BaseModel):
    """The agenda itself, as stored in the `agenda` JSONB column."""

    model_config = ConfigDict(from_attributes=True)

    items: list[AgendaItem] = Field(default_factory=list, max_length=50)
    action_items: list[AgendaActionItem] = Field(default_factory=list, max_length=50)


class AgendaSave(AgendaBody):
    """What the browser sends to PUT /meetings/{id}/agenda.

    `ai_suggestion` is what the parser proposed, exactly as it came back, together with the model
    and prompt version that produced it. The user may have edited every field since; that is the
    point of keeping both. Sent only when a parse was involved - saving a hand-written agenda
    leaves the earlier suggestion and its provenance untouched.
    """

    ai_suggestion: dict | None = None
    model: str | None = Field(default=None, max_length=100)
    prompt_version: str | None = Field(default=None, max_length=50)

    @model_validator(mode="after")
    def suggestion_names_its_model(self) -> "AgendaSave":
        if self.ai_suggestion is not None and not (self.model and self.prompt_version):
            raise ValueError("An ai_suggestion must come with its model and prompt_version")
        return self


class MeetingRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    description: str | None
    call_link: str | None
    place: str | None
    starts_at: datetime
    ends_at: datetime
    owner_id: UUID | None
    participants: list[ParticipantRead]
    agenda: AgendaBody | None
    ai_suggestion: dict | None
    ai_model: str | None
    ai_prompt_version: str | None
    created_at: datetime
