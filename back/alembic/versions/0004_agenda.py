"""Add the agenda, and what the model suggested for it.

`agenda` is the agenda the user saved; `ai_suggestion` is what the parser proposed for the same
meeting, kept verbatim so the two can be compared per prompt version later. All nullable: every
meeting that exists now simply has no agenda.

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-16
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("meetings", sa.Column("agenda", postgresql.JSONB(), nullable=True))
    op.add_column("meetings", sa.Column("ai_suggestion", postgresql.JSONB(), nullable=True))
    op.add_column("meetings", sa.Column("ai_model", sa.String(100), nullable=True))
    op.add_column("meetings", sa.Column("ai_prompt_version", sa.String(50), nullable=True))
    # The metric query ("is agenda-v2 better than agenda-v1") groups by prompt version over the
    # agendas that came from a model, which is a small slice of the table.
    op.create_index(
        "ix_meetings_ai_prompt_version",
        "meetings",
        ["ai_prompt_version"],
        postgresql_where=sa.text("ai_prompt_version IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_meetings_ai_prompt_version", table_name="meetings")
    op.drop_column("meetings", "ai_prompt_version")
    op.drop_column("meetings", "ai_model")
    op.drop_column("meetings", "ai_suggestion")
    op.drop_column("meetings", "agenda")
