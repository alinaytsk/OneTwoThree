import { screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it, vi } from "vitest"

import { MeetingFormDialog } from "@/components/MeetingFormDialog"
import type { ParseResult } from "@/types"
import { renderWithQuery, sampleMeeting } from "@/test/utils"

const PARSER_URL = "https://parser.test"

const PARSED: ParseResult = {
  agenda: {
    title: "Планування спринту",
    starts_at: "2026-10-20T15:00",
    duration_minutes: 45,
    items: [
      { topic: "Демо нового пошуку", owner: "Оля", minutes: 15 },
      { topic: "Ретро спринту", owner: null, minutes: null },
    ],
    action_items: [{ task: "Прислати макети", owner: "Іван", due: "2026-10-19" }],
    language: "uk",
  },
  model: "anthropic.claude-opus-5-5",
  prompt_version: "agenda-v1",
  usage: {
    model: "anthropic.claude-opus-5-5",
    prompt_version: "agenda-v1",
    input_tokens: 912,
    output_tokens: 133,
    attempts: 1,
    cost_usd: 0.006308,
  },
  latency_ms: 4120,
}

type Answer = { status?: number; body?: unknown }

/**
 * A fetch mock that tells the parser URL from the API, and lets a test keep the parser request
 * pending (to exercise the progress indicator and Cancel).
 */
function mockRequests(parser: Answer | "pending", api: Answer = { body: sampleMeeting }) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    if (url.startsWith(PARSER_URL)) {
      if (parser === "pending") {
        // Never resolves on its own; only an abort ends it, like a slow model call.
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () =>
            reject(new DOMException("Aborted", "AbortError")),
          )
        })
      }
      const { status = 200, body } = parser
      return new Response(JSON.stringify(body ?? null), {
        status,
        headers: { "Content-Type": "application/json" },
      })
    }
    // Each route answered with the shape its caller expects; everything else is the meeting.
    const answer: Answer = url.startsWith("/api/participants")
      ? { body: [] }
      : url === "/api/me"
        ? { body: null }
        : api
    const { status = 200, body } = answer
    return new Response(status === 204 ? null : JSON.stringify(body ?? null), {
      status,
      headers: { "Content-Type": "application/json" },
    })
  })
}

function renderDialog() {
  renderWithQuery(<MeetingFormDialog open onOpenChange={() => {}} meeting={sampleMeeting} />)
}

async function pasteAndParse(
  text = "Привіт! Плануємо спринт у вівторок о 15:00. Оля покаже демо.",
) {
  await userEvent.type(screen.getByLabelText("Paste an agenda"), text)
  await userEvent.click(screen.getByRole("button", { name: /Parse/ }))
}

describe("Paste an agenda", () => {
  it("fills the agenda form in and marks every field the model filled as suggested", async () => {
    mockRequests({ body: PARSED })
    renderDialog()

    await pasteAndParse()

    // Meeting-level fields the model read out of the text.
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: /^Title/ })).toHaveValue("Планування спринту"),
    )
    expect(screen.getByLabelText(/^Date/)).toHaveValue("2026-10-20")
    expect(screen.getByLabelText(/^Start/)).toHaveValue("15:00")
    // 15:00 plus the 45 minutes the text gave.
    expect(screen.getByLabelText(/^End/)).toHaveValue("15:45")

    // The agenda rows themselves.
    expect(screen.getByLabelText("Topic 1")).toHaveValue("Демо нового пошуку")
    expect(screen.getByLabelText("Owner of topic 1")).toHaveValue("Оля")
    expect(screen.getByLabelText("Minutes for topic 1")).toHaveValue(15)
    expect(screen.getByLabelText("Topic 2")).toHaveValue("Ретро спринту")
    expect(screen.getByLabelText("Task 1")).toHaveValue("Прислати макети")
    expect(screen.getByLabelText("Due date of task 1")).toHaveValue("2026-10-19")

    // What the model did not say stays empty and unmarked, rather than guessed.
    expect(screen.getByLabelText("Owner of topic 2")).toHaveValue("")
    // title, date, start, end + topic/owner/minutes 1 + topic 2 + task/owner/due 1 = 11
    expect(screen.getAllByText("suggested")).toHaveLength(11)
  })

  it("drops the suggested mark on a field as soon as the user edits it", async () => {
    mockRequests({ body: PARSED })
    renderDialog()
    await pasteAndParse()
    await waitFor(() => expect(screen.getByLabelText("Owner of topic 1")).toHaveValue("Оля"))

    const owner = screen.getByLabelText("Owner of topic 1")
    await userEvent.clear(owner)
    await userEvent.type(owner, "Ольга Шевченко")

    expect(owner).toHaveValue("Ольга Шевченко")
    // One mark fewer, and the other fields keep theirs.
    expect(screen.getAllByText("suggested")).toHaveLength(10)
  })

  it("saves through the API's agenda endpoint, with what the model proposed", async () => {
    const fetchMock = mockRequests({ body: PARSED })
    renderDialog()
    await pasteAndParse()
    await waitFor(() => expect(screen.getByLabelText("Topic 1")).toHaveValue("Демо нового пошуку"))

    const owner = screen.getByLabelText("Owner of topic 1")
    await userEvent.clear(owner)
    await userEvent.type(owner, "Ольга")
    await userEvent.click(screen.getByRole("button", { name: "Save changes" }))

    const agendaPut = await waitFor(() => {
      const call = fetchMock.mock.calls.find(([url]) =>
        String(url).endsWith(`/api/meetings/${sampleMeeting.id}/agenda`),
      )
      if (!call) throw new Error("the agenda was not saved")
      return call
    })
    const body = JSON.parse(String(agendaPut[1]?.body))

    // What the user kept.
    expect(body.items[0]).toEqual({ topic: "Демо нового пошуку", owner: "Ольга", minutes: 15 })
    expect(body.items[1]).toEqual({ topic: "Ретро спринту", owner: null, minutes: null })
    expect(body.action_items[0]).toEqual({
      task: "Прислати макети",
      owner: "Іван",
      due: "2026-10-19",
    })
    // And what the model had proposed, which is a different thing now.
    expect(body.ai_suggestion).toEqual(PARSED.agenda)
    expect(body.model).toBe("anthropic.claude-opus-5-5")
    expect(body.prompt_version).toBe("agenda-v1")

    // The save never goes to the parser's URL.
    const writesToParser = fetchMock.mock.calls.filter(
      ([url, init]) => String(url).startsWith(PARSER_URL) && init?.method !== "POST",
    )
    expect(writesToParser).toEqual([])
  })

  it("shows a progress indicator and cancels the request on Cancel", async () => {
    const fetchMock = mockRequests("pending")
    renderDialog()
    await pasteAndParse()

    expect(await screen.findByRole("status")).toHaveTextContent(/Reading the text/)
    const [, init] = fetchMock.mock.calls.find(([url]) => String(url).startsWith(PARSER_URL))!

    await userEvent.click(screen.getByRole("button", { name: "Cancel parsing" }))

    expect(init?.signal?.aborted).toBe(true)
    expect(await screen.findByText(/Parsing cancelled/)).toBeInTheDocument()
    // Cancelling leaves the form alone, to be filled in by hand.
    expect(screen.getByRole("button", { name: /Add item/ })).toBeEnabled()
  })

  it("refuses text over the limit before sending it anywhere", async () => {
    const fetchMock = mockRequests({ body: PARSED })
    renderDialog()

    // Pasting 10 001 characters, rather than typing them.
    const long = "х".repeat(10_001)
    await userEvent.click(screen.getByLabelText("Paste an agenda"))
    await userEvent.paste(long)

    // The number is formatted in the runtime's locale, so match around it rather than on it.
    expect(await screen.findByText(/over the .+ the parser accepts/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Parse/ })).toBeDisabled()
    expect(fetchMock.mock.calls.filter(([url]) => String(url).startsWith(PARSER_URL))).toEqual([])
  })

  it.each([
    [422, { error: "no_agenda", detail: "nope" }, /No agenda was found/],
    [413, { error: "too_long", detail: "too long" }, /too long to parse/],
    [429, { error: "throttled", detail: "slow down" }, /model is busy/],
    [502, { error: "model_unavailable", detail: "bedrock down" }, /parser is unavailable/],
    [401, { error: "unauthorized", detail: "no token" }, /session expired/i],
  ])("explains a %i from the parser in its own words", async (status, body, expected) => {
    mockRequests({ status, body })
    renderDialog()

    await pasteAndParse()

    expect(await screen.findByRole("alert")).toHaveTextContent(expected)
    // Whatever went wrong, the agenda can still be filled in by hand.
    expect(screen.getByRole("button", { name: /Add item/ })).toBeEnabled()
    expect(screen.getByRole("button", { name: "Save changes" })).toBeEnabled()
  })

  it("explains a network failure", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      if (String(input).startsWith(PARSER_URL)) throw new TypeError("Failed to fetch")
      const body = String(input).startsWith("/api/participants") ? [] : null
      return new Response(JSON.stringify(body), { status: 200 })
    })
    renderDialog()

    await pasteAndParse()

    expect(await screen.findByRole("alert")).toHaveTextContent(/Could not reach the parser/)
  })
})
