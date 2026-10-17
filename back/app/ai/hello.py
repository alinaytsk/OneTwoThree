"""`make llm-hello` - the smallest possible call to Claude on Bedrock, to prove access works.

Prints the answer, the stop reason and the token usage. If model access is not enabled in
Bedrock for this account and region, this is where it fails, with the API's own message, before
anything is deployed.

    uv run python -m app.ai.hello ["your prompt"]
"""

import sys

from app.ai.agenda import client, request_options
from app.config import settings

DEFAULT_PROMPT = "In one sentence: what belongs on a good meeting agenda?"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    prompt = " ".join(args).strip() or DEFAULT_PROMPT

    # The same client and the same options the parser itself uses, so this target fails exactly
    # where the parser would.
    response = client().messages.create(
        model=settings.parser_model,
        max_tokens=256,
        messages=[{"role": "user", "content": prompt}],
        **request_options(),
    )

    print(f"model:       {response.model}")
    print(f"backend:     {settings.parser_backend} ({type(client()).__name__})")
    print(f"region:      {settings.bedrock_region}")
    print(f"prompt:      {prompt}")
    for block in response.content:
        if block.type == "text":
            print(f"answer:      {block.text}")
    print(f"stop_reason: {response.stop_reason}")
    print(f"usage:       in={response.usage.input_tokens} out={response.usage.output_tokens}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
