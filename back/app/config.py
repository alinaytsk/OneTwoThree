from typing import TYPE_CHECKING

from pydantic_settings import BaseSettings, SettingsConfigDict

if TYPE_CHECKING:
    from sqlalchemy import URL


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Either a full DATABASE_URL (docker compose, tests) or separate DB_* parts (AWS Lambda,
    # where the password comes from Secrets Manager and may contain characters unsafe in a URL).
    database_url: str | None = None
    db_host: str = "localhost"
    db_port: int = 5432
    db_user: str = "meetings"
    db_password: str = "meetings"
    db_name: str = "meetings"
    # Open a connection per request instead of pooling (Lambda + Aurora Serverless: idle pooled
    # connections in warm execution environments would keep the database from pausing).
    db_null_pool: bool = False

    cors_origins: str = "http://localhost:3000,http://localhost:5173"
    seed: bool = False

    # Cognito user pool whose ID tokens the API accepts (`make aws-cognito-deploy` fills these in).
    # Empty pool ID = auth disabled: every request acts as one local user (local development, tests).
    cognito_region: str = "us-east-1"
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    # The pool's JWKS as JSON. Set on AWS, where the Lambda has no internet route to fetch it;
    # when empty it is downloaded from the issuer on first use.
    cognito_jwks: str = ""

    # --- Agenda parser (app.ai.agenda, the Lambda in infra/ai.yml) ---
    # Model on Bedrock, as a setting and not a constant: the same code has to be runnable against
    # a cheaper model without a redeploy of anything but the function's environment.
    parser_model: str = "anthropic.claude-opus-5-5"
    # Which Bedrock endpoint to reach that model through:
    #   mantle       the Messages API on Bedrock (AnthropicBedrockMantle). Takes base model ids
    #                such as anthropic.claude-opus-5-5. This is what the feature is built on.
    #   invoke_model the older bedrock-runtime path (AnthropicBedrock). This is the one that
    #                takes cross-region inference profile ids such as
    #                us.anthropic.claude-opus-5-5; the Mantle endpoint answers 404 for those.
    # Same SDK and the same request shape either way, so app/ai/agenda.py does not care.
    parser_backend: str = "mantle"
    bedrock_region: str = "us-east-1"
    # Rejected above this; a pasted email that long is not an agenda, and it caps the bill.
    parser_max_chars: int = 10_000
    # Bedrock prices in USD per million tokens, used to put a cost on every parse in the log line.
    # They belong in the environment, because a model change moves them.
    parser_price_in_per_mtok: float = 4.0
    parser_price_out_per_mtok: float = 20.0
    # Where those two numbers came from, logged next to the cost so nobody later reads a computed
    # figure as a billed one. `bedrock-rate-card` means they were read from this account's own
    # Marketplace offer for the model (true of the $4/$20 default, checked with
    # `aws bedrock list-foundation-model-agreement-offers`); `public-list` means they are the
    # published list price and were not confirmed against the account.
    parser_price_source: str = "bedrock-rate-card"
    # Extraction needs no deep reasoning; `low` keeps latency and output tokens down. Empty
    # means "do not send output_config at all": models before the 5 family reject the field with
    # 400 "output_config.effort: Extra inputs are not permitted".
    parser_effort: str = "low"
    # Timezone relative dates ("next Tuesday") are resolved in when the caller names none.
    parser_timezone: str = "Europe/Kyiv"

    @property
    def sqlalchemy_url(self) -> "URL":
        # Imported here rather than at module level: the agenda parser Lambda reads these same
        # settings and has no database, and SQLAlchemy is a second of cold start it never needs.
        from sqlalchemy import URL, make_url

        if self.database_url:
            return make_url(self.database_url)
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        )

    @property
    def auth_enabled(self) -> bool:
        return bool(self.cognito_user_pool_id)

    @property
    def cognito_issuer(self) -> str:
        return f"https://cognito-idp.{self.cognito_region}.amazonaws.com/{self.cognito_user_pool_id}"

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


settings = Settings()
