import { useRef, useState } from "react"
import { Loader2, Sparkles } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { MAX_PASTE_CHARS, parseAgenda, parserConfigured, parserErrorMessage } from "@/lib/parser"
import type { ParseResult } from "@/types"

/**
 * "Paste an agenda": a box for the email somebody forwarded, and a Parse button.
 *
 * A parse takes 2-8 seconds, so there is a progress line and a Cancel button that aborts the
 * request rather than only hiding the spinner. Every failure is reported in its own words, and
 * all of them say the same thing at the end: the form below still works by hand. Nothing here
 * writes anything - the parsed values go to the form, and the user saves them.
 */

interface PasteAgendaPanelProps {
  onParsed: (result: ParseResult) => void
  disabled?: boolean
}

export function PasteAgendaPanel({ onParsed, disabled }: PasteAgendaPanelProps) {
  const [text, setText] = useState("")
  const [parsing, setParsing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const abort = useRef<AbortController | null>(null)

  // Nothing to offer if this build has no parser URL; the agenda form below is unaffected.
  if (!parserConfigured()) return null

  const tooLong = text.length > MAX_PASTE_CHARS

  const parse = async () => {
    const controller = new AbortController()
    abort.current = controller
    setParsing(true)
    setError(null)
    setNote(null)
    try {
      const result = await parseAgenda(text, controller.signal)
      onParsed(result)
      setNote(
        `Filled in from the text in ${(result.latency_ms / 1000).toFixed(1)} s. Check the suggested fields before saving.`,
      )
    } catch (failure) {
      if (failure instanceof DOMException && failure.name === "AbortError") {
        setNote("Parsing cancelled. The form is still yours to fill in.")
      } else {
        setError(parserErrorMessage(failure))
      }
    } finally {
      setParsing(false)
      abort.current = null
    }
  }

  return (
    <div className="space-y-2 rounded-lg border border-dashed p-3">
      <div className="flex items-center justify-between gap-2">
        <Label htmlFor="paste-agenda">Paste an agenda</Label>
        <span className={tooLong ? "text-xs text-destructive" : "text-xs text-muted-foreground"}>
          {text.length.toLocaleString()} / {MAX_PASTE_CHARS.toLocaleString()}
        </span>
      </div>

      <Textarea
        id="paste-agenda"
        rows={4}
        placeholder="Paste the email or notes here, then press Parse. The agenda form below fills in; you stay in charge of every field."
        value={text}
        disabled={disabled || parsing}
        onChange={(event) => setText(event.target.value)}
      />

      <div className="flex flex-wrap items-center gap-2">
        {parsing ? (
          <>
            <span role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="size-4 animate-spin" />
              Reading the text… this takes a few seconds
            </span>
            <Button
              type="button"
              variant="outline"
              size="sm"
              // Distinct from the dialog's own Cancel button, for anyone reading the page by name.
              aria-label="Cancel parsing"
              onClick={() => abort.current?.abort()}
            >
              Cancel
            </Button>
          </>
        ) : (
          <Button
            type="button"
            variant="secondary"
            size="sm"
            disabled={disabled || text.trim() === "" || tooLong}
            onClick={parse}
          >
            <Sparkles className="size-4" /> Parse
          </Button>
        )}
      </div>

      {tooLong && !parsing && (
        <p className="text-sm text-destructive">
          {`That text is ${text.length.toLocaleString()} characters, over the ${MAX_PASTE_CHARS.toLocaleString()} the parser accepts. Paste the agenda part of it, or fill the form in by hand.`}
        </p>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {note && !error && <p className="text-sm text-muted-foreground">{note}</p>}
    </div>
  )
}
