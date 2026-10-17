import os
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.db import Base, get_db
from app.main import app

TEST_DATABASE_URL = os.getenv(
    "TEST_DATABASE_URL", "postgresql+psycopg://meetings:meetings@localhost:5432/meetings_test"
)

engine = create_engine(TEST_DATABASE_URL)
TestingSession = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


# Requested by the `client` fixture rather than autouse: the tests that mock the model away
# (tests/test_agenda_parser.py, tests/test_agenda_lambda.py) need no database at all, and should
# not need one running to pass.
@pytest.fixture(scope="session")
def schema() -> Iterator[None]:
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield
    Base.metadata.drop_all(engine)


@pytest.fixture
def client(schema: None) -> Iterator[TestClient]:
    def override_get_db() -> Iterator[Session]:
        with TestingSession() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()

    with engine.begin() as conn:
        conn.execute(text("TRUNCATE meeting_participants, meetings, participants, users"))
