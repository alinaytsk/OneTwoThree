import { getIdToken } from "@/lib/auth"
import type { ParseResult } from "@/types"

/**
 * The agenda parser's own Lambda function URL - a different origin from the API.
 *
 * Only parsing goes here. Saving goes through the API (`PUT /meetings/{id}/agenda`), because
 * this function has no database behind it: it can read the pasted text and call the model, and
 * that is all it can do.
 */
const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? "").replace(/\/+$/, "")

/** Matches PARSER_MAX_CHARS on the Lambda, which answers 413 above it. */
export const MAX_PASTE_CHARS = 10000

/** Without a parser URL in the build, the paste box is not offered at all. */
export function parserConfigured(): boolean {
  return PARSER_URL !== ""
}

export type ParserErrorCode =
  | "too_long"
  | "no_agenda"
  | "invalid_output"
  | "throttled"
  | "model_unavailable"
  | "unauthorized"
  | "bad_request"
  | "network"
  | "unknown"

export class ParserError extends Error {
  readonly code: ParserErrorCode

  constructor(code: ParserErrorCode, message: string) {
    super(message)
    this.name = "ParserError"
    this.code = code
  }
}

/** What each failure means to someone who just pasted an email and is waiting. */
export function parserErrorMessage(error: unknown): string {
  if (!(error instanceof ParserError))
    return "Could not parse the text. Fill the agenda in by hand."
  switch (error.code) {
    case "too_long":
      return `That text is too long to parse (limit ${MAX_PASTE_CHARS.toLocaleString()} characters). Paste the agenda part of it, or fill the form in by hand.`
    case "no_agenda":
      return "No agenda was found in that text. Check that you pasted the right part, or fill the form in by hand."
    case "invalid_output":
      return "The agenda came back in a shape we could not use. Try again, or fill the form in by hand."
    case "throttled":
      return "The model is busy right now. Wait a few seconds and try again, or fill the form in by hand."
    case "model_unavailable":
      return "The parser is unavailable right now. The form below still works by hand."
    case "unauthorized":
      return "Your session expired. Sign in again to parse text."
    case "network":
      return "Could not reach the parser. Check your connection, or fill the form in by hand."
    default:
      return "Could not parse the text. Fill the agenda in by hand."
  }
}

const CODES: ParserErrorCode[] = [
  "too_long",
  "no_agenda",
  "invalid_output",
  "throttled",
  "model_unavailable",
  "unauthorized",
  "bad_request",
]

function codeFrom(body: unknown, status: number): ParserErrorCode {
  const reported = (body as { error?: string } | null)?.error
  if (reported && (CODES as string[]).includes(reported)) return reported as ParserErrorCode
  if (status === 401 || status === 403) return "unauthorized"
  if (status === 413) return "too_long"
  if (status === 429) return "throttled"
  if (status >= 500) return "model_unavailable"
  return "unknown"
}

/**
 * Send pasted text to the parser. `signal` comes from an AbortController, so the Cancel button
 * next to the progress indicator actually stops waiting for the answer.
 */
export async function parseAgenda(text: string, signal?: AbortSignal): Promise<ParseResult> {
  if (!parserConfigured()) {
    throw new ParserError("model_unavailable", "No parser URL in this build")
  }
  // Checked here as well as on the Lambda: there is no reason to send 50 KB across the network
  // to be told it is too long.
  if (text.length > MAX_PASTE_CHARS) {
    throw new ParserError("too_long", `${text.length} characters, limit ${MAX_PASTE_CHARS}`)
  }

  const token = await getIdToken()
  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ text }),
      signal,
    })
  } catch (error) {
    // An aborted request is the user's own doing; the caller tells the two apart.
    if (error instanceof DOMException && error.name === "AbortError") throw error
    throw new ParserError("network", error instanceof Error ? error.message : "Network error")
  }

  if (!response.ok) {
    let body: unknown = null
    try {
      body = await response.json()
    } catch {
      // A non-JSON error body (a gateway page, say) leaves the status to speak for itself.
    }
    const detail = (body as { detail?: string } | null)?.detail
    throw new ParserError(
      codeFrom(body, response.status),
      detail ?? `Parser failed (${response.status})`,
    )
  }

  return (await response.json()) as ParseResult
}
