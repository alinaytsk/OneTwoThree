export interface Participant {
  id: string
  name: string
  email: string
}

export interface User {
  id: string
  email: string
  name: string | null
}

export interface AgendaItem {
  topic: string
  owner: string | null
  minutes: number | null
}

export interface AgendaActionItem {
  task: string
  owner: string | null
  /** ISO date (YYYY-MM-DD). */
  due: string | null
}

/** The agenda as it is stored with the meeting. */
export interface Agenda {
  items: AgendaItem[]
  action_items: AgendaActionItem[]
}

/** What the parser proposed: the agenda plus the meeting-level fields it read out of the text. */
export interface ParsedAgenda extends Agenda {
  title: string
  /** ISO local date-time (YYYY-MM-DDTHH:MM), or null when the text named no start. */
  starts_at: string | null
  duration_minutes: number | null
  language: string
}

/** The parser Lambda's answer, including what the call cost. */
export interface ParseResult {
  agenda: ParsedAgenda
  model: string
  prompt_version: string
  usage: {
    model: string
    prompt_version: string
    input_tokens: number
    output_tokens: number
    attempts: number
    cost_usd: number
  }
  latency_ms: number
}

/** The body of PUT /meetings/{id}/agenda. */
export interface AgendaSave extends Agenda {
  /** What the model proposed, verbatim; sent only when this save came out of a parse. */
  ai_suggestion?: ParsedAgenda | null
  model?: string | null
  prompt_version?: string | null
}

export interface Meeting {
  id: string
  title: string
  description: string | null
  call_link: string | null
  place: string | null
  starts_at: string
  ends_at: string
  owner_id: string | null
  participants: Participant[]
  agenda: Agenda | null
  ai_suggestion: ParsedAgenda | null
  ai_model: string | null
  ai_prompt_version: string | null
  created_at: string
}

export interface MeetingCreate {
  title: string
  description: string | null
  call_link: string | null
  place: string | null
  starts_at: string
  ends_at: string
  participant_ids: string[]
}

export interface ParticipantCreate {
  name: string
  email: string
}

/** One entry of FastAPI's 422 `detail` list. */
export interface ValidationIssue {
  loc: (string | number)[]
  msg: string
  type: string
}
