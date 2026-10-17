import type { Agenda, ParsedAgenda } from "@/types"

/**
 * The agenda as the form holds it while it is being edited.
 *
 * Values are strings, because that is what inputs hold, and every field carries a `suggested`
 * flag: true while it still holds what the model proposed. Per field, not per row - the
 * interesting case is the mixed one, where the topic was right and the owner was not.
 */

export interface DraftItem {
  topic: string
  owner: string
  minutes: string
  suggested: { topic: boolean; owner: boolean; minutes: boolean }
}

export interface DraftAction {
  task: string
  owner: string
  due: string
  suggested: { task: boolean; owner: boolean; due: boolean }
}

export interface AgendaDraft {
  items: DraftItem[]
  action_items: DraftAction[]
}

const NOTHING_SUGGESTED_ITEM = { topic: false, owner: false, minutes: false }
const NOTHING_SUGGESTED_ACTION = { task: false, owner: false, due: false }

export function emptyItem(): DraftItem {
  return { topic: "", owner: "", minutes: "", suggested: { ...NOTHING_SUGGESTED_ITEM } }
}

export function emptyAction(): DraftAction {
  return { task: "", owner: "", due: "", suggested: { ...NOTHING_SUGGESTED_ACTION } }
}

export function emptyDraft(): AgendaDraft {
  return { items: [], action_items: [] }
}

/** An agenda the user saved earlier: nothing is "suggested" any more, it is just their agenda. */
export function draftFromAgenda(agenda: Agenda | null): AgendaDraft {
  if (!agenda) return emptyDraft()
  return {
    items: agenda.items.map((item) => ({
      topic: item.topic,
      owner: item.owner ?? "",
      minutes: item.minutes?.toString() ?? "",
      suggested: { ...NOTHING_SUGGESTED_ITEM },
    })),
    action_items: agenda.action_items.map((action) => ({
      task: action.task,
      owner: action.owner ?? "",
      due: action.due ?? "",
      suggested: { ...NOTHING_SUGGESTED_ACTION },
    })),
  }
}

/** A fresh parse: every value that came back non-empty is marked as the model's suggestion. */
export function draftFromParsed(parsed: ParsedAgenda): AgendaDraft {
  return {
    items: parsed.items.map((item) => ({
      topic: item.topic,
      owner: item.owner ?? "",
      minutes: item.minutes?.toString() ?? "",
      suggested: {
        topic: item.topic !== "",
        owner: item.owner != null,
        minutes: item.minutes != null,
      },
    })),
    action_items: parsed.action_items.map((action) => ({
      task: action.task,
      owner: action.owner ?? "",
      due: action.due ?? "",
      suggested: {
        task: action.task !== "",
        owner: action.owner != null,
        due: action.due != null,
      },
    })),
  }
}

/** What goes to the API: blank strings become nulls, and rows with no topic or task are dropped. */
export function agendaFromDraft(draft: AgendaDraft): Agenda {
  return {
    items: draft.items
      .filter((item) => item.topic.trim() !== "")
      .map((item) => ({
        topic: item.topic.trim(),
        owner: item.owner.trim() || null,
        minutes: item.minutes.trim() === "" ? null : Number(item.minutes),
      })),
    action_items: draft.action_items
      .filter((action) => action.task.trim() !== "")
      .map((action) => ({
        task: action.task.trim(),
        owner: action.owner.trim() || null,
        due: action.due.trim() || null,
      })),
  }
}

/** Editing a field is the user taking it over: the mark goes, and does not come back. */
export function withItemEdited(
  draft: AgendaDraft,
  index: number,
  field: "topic" | "owner" | "minutes",
  text: string,
): AgendaDraft {
  return {
    ...draft,
    items: draft.items.map((item, i) =>
      i === index
        ? { ...item, [field]: text, suggested: { ...item.suggested, [field]: false } }
        : item,
    ),
  }
}

export function withActionEdited(
  draft: AgendaDraft,
  index: number,
  field: "task" | "owner" | "due",
  text: string,
): AgendaDraft {
  return {
    ...draft,
    action_items: draft.action_items.map((action, i) =>
      i === index
        ? { ...action, [field]: text, suggested: { ...action.suggested, [field]: false } }
        : action,
    ),
  }
}
