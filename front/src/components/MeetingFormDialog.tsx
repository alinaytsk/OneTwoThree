import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { toast } from "sonner"
import { z } from "zod"

import { AgendaFields } from "@/components/AgendaFields"
import { ParticipantsMultiSelect } from "@/components/ParticipantsMultiSelect"
import { PasteAgendaPanel } from "@/components/PasteAgendaPanel"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { useCreateMeeting, useSaveAgenda, useUpdateMeeting } from "@/hooks/useMeetings"
import { agendaFromDraft, draftFromAgenda, draftFromParsed, type AgendaDraft } from "@/lib/agenda"
import { ApiError } from "@/lib/api"
import { toDateInput, toTimeInput } from "@/lib/calendar"
import type { Meeting, MeetingCreate, ParseResult } from "@/types"

const meetingSchema = z
  .object({
    title: z.string().trim().min(1, "Title is required").max(200, "Max 200 characters"),
    description: z.string().max(5000, "Max 5000 characters"),
    call_link: z.union([
      z.literal(""),
      z.url({ protocol: /^https?$/, message: "Enter a valid http(s) URL" }),
    ]),
    place: z.string().trim().max(255, "Max 255 characters"),
    date: z.string().min(1, "Date is required"),
    start_time: z.string().min(1, "Start time is required"),
    end_time: z.string().min(1, "End time is required"),
    participants: z.array(z.object({ id: z.string(), name: z.string(), email: z.string() })),
  })
  .refine((values) => values.call_link !== "" || values.place !== "", {
    message: "Provide a call link, a place, or both",
    path: ["place"],
  })
  .refine(
    (values) => !values.start_time || !values.end_time || values.end_time > values.start_time,
    {
      message: "End must be after start",
      path: ["end_time"],
    },
  )

type MeetingFormValues = z.infer<typeof meetingSchema>

/** The meeting fields the parser can fill in, and which can therefore be marked "suggested". */
type SuggestibleField = "title" | "date" | "start_time" | "end_time"

/** Defaults to the next full hour, one hour long, kept within the same day. */
function emptyValues(start?: Date): MeetingFormValues {
  if (!start) {
    start = new Date()
    start.setHours(start.getHours() + 1, 0, 0, 0)
  }
  const end = new Date(start.getTime() + 60 * 60_000)
  return {
    title: "",
    description: "",
    call_link: "",
    place: "",
    date: toDateInput(start),
    start_time: toTimeInput(start),
    end_time: end.getDate() === start.getDate() ? toTimeInput(end) : "23:59",
    participants: [],
  }
}

function meetingValues(meeting: Meeting): MeetingFormValues {
  const start = new Date(meeting.starts_at)
  return {
    title: meeting.title,
    description: meeting.description ?? "",
    call_link: meeting.call_link ?? "",
    place: meeting.place ?? "",
    date: toDateInput(start),
    start_time: toTimeInput(start),
    end_time: toTimeInput(new Date(meeting.ends_at)),
    participants: meeting.participants,
  }
}

const API_FIELD_TO_FORM: Record<string, keyof MeetingFormValues> = {
  title: "title",
  description: "description",
  call_link: "call_link",
  place: "place",
  participant_ids: "participants",
  starts_at: "start_time",
  ends_at: "end_time",
}

/** "2026-10-20T15:00" -> the date and time parts the two inputs hold, or null if unusable. */
function splitLocal(value: string): { date: string; time: string } | null {
  const match = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})/.exec(value)
  return match ? { date: match[1], time: match[2] } : null
}

function addMinutes(time: string, minutes: number): string | null {
  const parts = /^(\d{2}):(\d{2})$/.exec(time)
  if (!parts) return null
  const total = Number(parts[1]) * 60 + Number(parts[2]) + minutes
  // A meeting that would run past midnight keeps whatever end time is already in the form:
  // moving the date here would be inventing a value the text did not contain.
  if (total >= 24 * 60) return null
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${pad(Math.floor(total / 60))}:${pad(total % 60)}`
}

interface MeetingFormProps {
  onOpenChange: (open: boolean) => void
  initialStart?: Date
  meeting?: Meeting | null
}

/**
 * The form itself. Mounted fresh every time the dialog opens (see the `key` below), so the
 * meeting fields, the agenda rows and the "suggested" marks all start from the same state
 * without an effect to reset them.
 */
function MeetingForm({ onOpenChange, initialStart, meeting }: MeetingFormProps) {
  const createMeeting = useCreateMeeting()
  const updateMeeting = useUpdateMeeting()
  const saveAgenda = useSaveAgenda()
  const saving = createMeeting.isPending || updateMeeting.isPending || saveAgenda.isPending
  const form = useForm<MeetingFormValues>({
    resolver: zodResolver(meetingSchema),
    defaultValues: meeting ? meetingValues(meeting) : emptyValues(initialStart),
  })

  const [agenda, setAgenda] = useState<AgendaDraft>(() => draftFromAgenda(meeting?.agenda ?? null))
  // Which meeting fields still hold the model's value, and the parse to store with the save.
  const [suggested, setSuggested] = useState<Partial<Record<SuggestibleField, boolean>>>({})
  const [suggestion, setSuggestion] = useState<ParseResult | null>(null)

  /** Fill the form in from a parse. Nothing is saved here - the user still presses Save. */
  const applyParsed = (result: ParseResult) => {
    const parsed = result.agenda
    const marks: Partial<Record<SuggestibleField, boolean>> = {}

    if (parsed.title) {
      form.setValue("title", parsed.title, { shouldValidate: true })
      marks.title = true
    }
    const start = parsed.starts_at ? splitLocal(parsed.starts_at) : null
    if (start) {
      form.setValue("date", start.date, { shouldValidate: true })
      form.setValue("start_time", start.time, { shouldValidate: true })
      marks.date = true
      marks.start_time = true
      if (parsed.duration_minutes) {
        const end = addMinutes(start.time, parsed.duration_minutes)
        if (end) {
          form.setValue("end_time", end, { shouldValidate: true })
          marks.end_time = true
        }
      }
    }

    setAgenda(draftFromParsed(parsed))
    setSuggested(marks)
    setSuggestion(result)
  }

  /** The user typing in a field is them taking it over, so the mark goes for good. */
  const taken = (field: SuggestibleField) =>
    setSuggested((marks) => (marks[field] ? { ...marks, [field]: false } : marks))

  const suggestedMark = (field: SuggestibleField) =>
    suggested[field] ? (
      <Badge variant="secondary" className="font-normal">
        suggested
      </Badge>
    ) : null

  const onSubmit = async (values: MeetingFormValues) => {
    const data: MeetingCreate = {
      title: values.title,
      description: values.description.trim() || null,
      call_link: values.call_link || null,
      place: values.place || null,
      starts_at: new Date(`${values.date}T${values.start_time}`).toISOString(),
      ends_at: new Date(`${values.date}T${values.end_time}`).toISOString(),
      participant_ids: values.participants.map((p) => p.id),
    }
    try {
      const saved = meeting
        ? await updateMeeting.mutateAsync({ id: meeting.id, data })
        : await createMeeting.mutateAsync(data)

      // The agenda goes to the API's own agenda endpoint, never to the parser's URL - and with
      // it, what the model proposed, so the two can be compared later.
      const body = agendaFromDraft(agenda)
      const hasAgenda = body.items.length > 0 || body.action_items.length > 0
      if (hasAgenda || meeting?.agenda) {
        await saveAgenda.mutateAsync({
          id: saved.id,
          data: suggestion
            ? {
                ...body,
                ai_suggestion: suggestion.agenda,
                model: suggestion.model,
                prompt_version: suggestion.prompt_version,
              }
            : body,
        })
      }

      toast.success(meeting ? "Meeting updated" : "Meeting created")
      onOpenChange(false)
    } catch (error) {
      if (error instanceof ApiError && error.status === 422 && error.issues.length > 0) {
        for (const issue of error.issues) {
          const field = API_FIELD_TO_FORM[String(issue.loc[1])]
          form.setError(field ?? "root", { message: issue.msg })
        }
        return
      }
      toast.error(
        error instanceof Error ? error.message : `Could not ${meeting ? "save" : "create"} meeting`,
      )
    }
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4" noValidate>
        <FormField
          control={form.control}
          name="title"
          render={({ field }) => (
            <FormItem>
              <FormLabel className="flex items-center gap-2">
                Title {suggestedMark("title")}
              </FormLabel>
              <FormControl>
                <Input
                  placeholder="Sprint planning"
                  {...field}
                  onChange={(event) => {
                    taken("title")
                    field.onChange(event)
                  }}
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <div className="grid gap-4 sm:grid-cols-[1.4fr_1fr_1fr]">
          <FormField
            control={form.control}
            name="date"
            render={({ field }) => (
              <FormItem>
                <FormLabel className="flex items-center gap-2">
                  Date {suggestedMark("date")}
                </FormLabel>
                <FormControl>
                  <Input
                    type="date"
                    {...field}
                    onChange={(event) => {
                      taken("date")
                      field.onChange(event)
                    }}
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="start_time"
            render={({ field }) => (
              <FormItem>
                <FormLabel className="flex items-center gap-2">
                  Start {suggestedMark("start_time")}
                </FormLabel>
                <FormControl>
                  <Input
                    type="time"
                    {...field}
                    onChange={(event) => {
                      taken("start_time")
                      field.onChange(event)
                    }}
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="end_time"
            render={({ field }) => (
              <FormItem>
                <FormLabel className="flex items-center gap-2">
                  End {suggestedMark("end_time")}
                </FormLabel>
                <FormControl>
                  <Input
                    type="time"
                    {...field}
                    onChange={(event) => {
                      taken("end_time")
                      field.onChange(event)
                    }}
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>
        <FormField
          control={form.control}
          name="description"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Description</FormLabel>
              <FormControl>
                <Textarea placeholder="What is this meeting about?" rows={3} {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="participants"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Participants</FormLabel>
              <FormControl>
                <ParticipantsMultiSelect value={field.value} onChange={field.onChange} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="call_link"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Call link</FormLabel>
                <FormControl>
                  <Input type="url" placeholder="https://meet.google.com/…" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="place"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Place</FormLabel>
                <FormControl>
                  <Input placeholder="Room 204" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        {/* The agenda: the same form whether it was typed or parsed. */}
        <div className="space-y-3 border-t pt-4">
          <PasteAgendaPanel onParsed={applyParsed} disabled={saving} />
          <AgendaFields value={agenda} onChange={setAgenda} disabled={saving} />
        </div>

        {form.formState.errors.root && (
          <p className="text-sm text-destructive">{form.formState.errors.root.message}</p>
        )}

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button type="submit" disabled={saving}>
            {meeting
              ? saving
                ? "Saving…"
                : "Save changes"
              : saving
                ? "Creating…"
                : "Create meeting"}
          </Button>
        </DialogFooter>
      </form>
    </Form>
  )
}

interface MeetingFormDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Prefills the date and time, e.g. from a clicked calendar slot. */
  initialStart?: Date
  /** Edits this meeting instead of creating a new one. */
  meeting?: Meeting | null
}

export function MeetingFormDialog({
  open,
  onOpenChange,
  initialStart,
  meeting,
}: MeetingFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{meeting ? "Edit meeting" : "New meeting"}</DialogTitle>
          <DialogDescription>
            Add a call link, a place, or both so people know where to go.
          </DialogDescription>
        </DialogHeader>

        {open && (
          <MeetingForm
            // Remounting on open (and on which meeting) is what resets the form, the agenda rows
            // and the suggestion marks - no effect, nothing left over from the last time.
            key={`${meeting?.id ?? "new"}-${initialStart?.toISOString() ?? ""}`}
            onOpenChange={onOpenChange}
            initialStart={initialStart}
            meeting={meeting}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}
