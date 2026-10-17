# 6. Parsing a pasted agenda with an LLM

Date: 2026-10-16

Status: Accepted

## Context

Agendas reach people as prose. Somebody forwards an email - "Привіт! Плануємо спринт у вівторок
о 15:00, Оля покаже демо нового пошуку (15 хв), потім ретро. Іван, пришли макети до понеділка" -
and the person who has to put that meeting in the app retypes it: a title, a date, a start time,
three agenda points with owners and minutes, one action item with a deadline. It is two minutes
of copying for something a model reads in four seconds.

Until this change the app had no agenda at all: a meeting was a title, a description, a time, a
place and participants ([0004_agenda.py](../../back/alembic/versions/0004_agenda.py) adds the
agenda itself). So this feature adds both the agenda and the way to fill it in from text.

The constraints that shaped the design come from the three labs before it:

- The API runs as a Lambda **inside a VPC** with no NAT gateway and no internet route, because
  Aurora Serverless is in that VPC. Anything inside that needs a public endpoint needs a VPC
  interface endpoint, at $7.30/month each (this is also why the weekly report splits into a
  builder inside the VPC and a mailer outside it - see [reports.yml](../../infra/reports.yml)).
- Sign-in is Cognito; the browser already holds an ID token and the API already verifies it
  locally against the pool's JWKS.
- The account is a student account with a tiny budget, and a model call is the first thing in
  this system whose cost scales with use rather than with time.

## Decision

A **separate Lambda, outside the VPC**, behind its own function URL, which the browser calls
directly with the pasted text and the Cognito ID token it already has. It runs the same backend
image as the API on a different command (`app.ai.agenda_lambda.handler`), has no `VpcConfig`, no
database credentials in its environment, and one IAM action to its name:
`bedrock-mantle:CreateInference`. It answers with JSON and writes nothing anywhere.

**The model is `anthropic.claude-opus-5-5` on Bedrock**, reached through the Anthropic Messages
API (the `AnthropicBedrockMantle` client), at effort `low`. The model id, the effort and the
prices used for the cost line are environment settings, not constants: swapping in
`anthropic.claude-haiku-5-5` (40x cheaper per token) is a stack parameter, not a code change.
Opus is the default because the hard parts of this task are the ones a smaller model is worst
at - Ukrainian text, names in a different script that must be copied letter for letter, and
relative dates resolved against today - and because at a few agendas per week per organisation
the absolute bill is cents either way (the numbers are in Consequences).

**The model answers by calling one tool, `record_agenda`, and never writes anything.** Its
answer is a function argument, validated against a Pydantic schema; what comes back is a filled
form, which the user reads, corrects, and saves themselves. There is no path from the model's
output to the database that does not go through a person pressing Save. Saving goes to the
API's own endpoint (`PUT /api/meetings/{id}/agenda`) with the user's token, under the same
ownership checks as every other write - the parser's URL cannot save an agenda even if it wanted
to, because it has no route to the database.

Three further decisions inside that:

- **Why outside the VPC.** The function needs Bedrock (public endpoint) and the Cognito JWKS
  (public endpoint). It needs no database. Putting it outside the VPC costs nothing and avoids a
  $7.30/month interface endpoint - but the real reason is the other direction: the component the
  browser can hand 10 000 characters of untrusted text to is the component with no route to the
  meetings data. The injection test case below is contained by that fact, not by the prompt.
- **Why a function URL with `AuthType: NONE`.** The caller is a browser holding a Cognito ID
  token, not SigV4 credentials, so AWS cannot check it for us; the handler verifies the token
  itself with the same code as the API (`app.auth_tokens`, extracted so the parser does not drag
  FastAPI and SQLAlchemy in). `AuthType: NONE` means "AWS does not check", not "nobody checks".
- **Why one retry and then an error.** `strict: true` makes the API guarantee the arguments
  match the JSON schema, but not that `due` is a real date or that `minutes` is positive.
  Pydantic checks that, and on failure the error text goes back to the model as a `tool_result`
  with `is_error`, which gets one chance to fix it. A second failure is an error the user sees,
  not a third call: a model that answers the same way twice will answer the same way five times,
  and each attempt costs money and seconds.

## Alternatives considered

**Bedrock from the API, through a VPC interface endpoint.** One component fewer, one URL fewer,
no CORS. Rejected on cost and on blast radius: $7.30/month for the endpoint is most of this
account's monthly budget, and it would mean the code that reads untrusted pasted text runs in
the same function, with the same database credentials, as every other API request. The split
costs us a second deployable and buys a component that cannot leak meeting data however it is
prompted.

**The Anthropic API directly, instead of Bedrock.** Fewer moving parts - an API key and an HTTPS
call, no IAM, no model access to enable. Rejected because the key would have to live somewhere
(Secrets Manager, another dependency, or an environment variable in a public-URL Lambda), while
Bedrock authenticates with the function's own IAM role and nothing else; because the spend shows
up in the same AWS bill as everything else, under the same Budgets alarm, instead of a second
account to watch; and because the data stays inside the account's AWS region.

**A regex / rule-based parser.** No model, no cost, no latency, deterministic and testable.
Rejected after writing out what it has to handle: "у вівторок о 15:00" and "next Tuesday after
lunch" and "by end of week"; "Оля покаже демо (15 хв)" and "Demo - Olya - 15 min" and "15'";
titles that are email subject lines with "Re: Fwd:" on them; greetings and signatures that are
not agenda items. Each of those is a rule, every rule has exceptions in two languages, and the
failure mode of a rule-based parser is silent nonsense rather than an empty field. We would have
spent the lab on a worse parser. A small set of rules does survive, in the places where rules
are better than a model: the 10 000-character limit, the schema, and the validation.

## Consequences

**Cost.** Billed per token, at Bedrock's Opus 5.5 price of $4 per million input tokens and $20
per million output (confirmed against the model's own Marketplace rate card, not assumed). Most
of the input of any single parse is fixed overhead - the system prompt and the tool schema - so
the per-parse cost barely moves with the length of the paste. The measured numbers, and the
arithmetic for twenty organisations at 30 agendas a week against the $7.30/month of one VPC
interface endpoint, are in [submission.md](../../submission.md); this design trades a fixed
monthly cost for a variable one that is zero when nobody pastes anything.
`PARSER_MODEL=anthropic.claude-haiku-5-5` divides the token cost by roughly 40 for the same
volume, which is the lever to pull if parsing becomes routine rather than occasional. A monthly
AWS Budgets alarm at $5 with an email at 80% actual and 100% forecast is part of the stack
([ai.yml](../../infra/ai.yml)), and the 10 000-character limit is enforced before the model is
called, so a pasted book costs nothing.

**What is logged.** One JSON line per parse, in the parser's own log group, with a seven-day
retention: the user's email, the outcome, the model, the prompt version, input and output
tokens, how many attempts it took, the latency, the cost in dollars, and the length of the text.
**Not the text itself** - these are somebody's meeting notes, and a log group is the wrong place
for them. That line is what makes the cost question answerable from data instead of from
estimates, and what a Logs Insights query groups by `prompt_version` to compare two prompts.

**What is stored.** Alongside the agenda the user saved, `ai_suggestion` keeps what the model
proposed, verbatim, with `ai_model` and `ai_prompt_version`. Saving a hand-written agenda later
does not overwrite that record. The pair (what was proposed, what was kept) is the only honest
measure of whether a prompt change helped, and it accumulates for free as people use the
feature.

**When Bedrock is down or throttling.** Nothing else breaks. The parser answers 429 or 502, the
UI says so in those words, and the agenda form underneath is exactly the form it would have been
without this feature: the user types the agenda. No queue, no retry in the background, no
half-saved state - the feature degrades to the hand-written path it was built next to. The same
is true when the text is not an agenda at all: the model declines to call the tool, the user
gets "no agenda was found in that text", and the form stays theirs.

**What the model can still get wrong.** It can normalise a name, miss an owner, or resolve a
relative date to the wrong day, and the `suggested` marks in the UI exist because of that: every
field the model filled is marked until the user touches it, so a wrong value is visible as "not
checked yet" rather than as data. The measured results, including an injection attempt, are in
[submission.md](../../submission.md).
