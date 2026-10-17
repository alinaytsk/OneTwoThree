import { Plus, X } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  emptyAction,
  emptyItem,
  withActionEdited,
  withItemEdited,
  type AgendaDraft,
} from "@/lib/agenda"

/**
 * The agenda form: the same rows whether they were typed or parsed. A field the model filled in
 * carries a "suggested" badge until the user edits it (see `withItemEdited` in lib/agenda).
 */

function SuggestedMark({ show }: { show: boolean }) {
  if (!show) return null
  return (
    <Badge variant="secondary" className="mt-1 font-normal">
      suggested
    </Badge>
  )
}

interface AgendaFieldsProps {
  value: AgendaDraft
  onChange: (draft: AgendaDraft) => void
  disabled?: boolean
}

export function AgendaFields({ value, onChange, disabled }: AgendaFieldsProps) {
  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <Label>Agenda items</Label>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={disabled}
            onClick={() => onChange({ ...value, items: [...value.items, emptyItem()] })}
          >
            <Plus className="size-4" /> Add item
          </Button>
        </div>

        {value.items.length === 0 && (
          <p className="text-sm text-muted-foreground">
            No agenda yet. Add items by hand, or paste the text above and parse it.
          </p>
        )}

        {value.items.map((item, index) => (
          <div key={index} className="grid gap-2 sm:grid-cols-[1fr_10rem_6rem_auto]">
            <div>
              <Input
                aria-label={`Topic ${index + 1}`}
                placeholder="What is discussed"
                value={item.topic}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withItemEdited(value, index, "topic", event.target.value))
                }
              />
              <SuggestedMark show={item.suggested.topic} />
            </div>
            <div>
              <Input
                aria-label={`Owner of topic ${index + 1}`}
                placeholder="Owner"
                value={item.owner}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withItemEdited(value, index, "owner", event.target.value))
                }
              />
              <SuggestedMark show={item.suggested.owner} />
            </div>
            <div>
              <Input
                aria-label={`Minutes for topic ${index + 1}`}
                placeholder="Min"
                type="number"
                min={1}
                max={600}
                value={item.minutes}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withItemEdited(value, index, "minutes", event.target.value))
                }
              />
              <SuggestedMark show={item.suggested.minutes} />
            </div>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              aria-label={`Remove topic ${index + 1}`}
              disabled={disabled}
              onClick={() =>
                onChange({ ...value, items: value.items.filter((_, i) => i !== index) })
              }
            >
              <X className="size-4" />
            </Button>
          </div>
        ))}
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <Label>Action items</Label>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={disabled}
            onClick={() =>
              onChange({ ...value, action_items: [...value.action_items, emptyAction()] })
            }
          >
            <Plus className="size-4" /> Add action
          </Button>
        </div>

        {value.action_items.map((action, index) => (
          <div key={index} className="grid gap-2 sm:grid-cols-[1fr_10rem_9rem_auto]">
            <div>
              <Input
                aria-label={`Task ${index + 1}`}
                placeholder="What has to be done"
                value={action.task}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withActionEdited(value, index, "task", event.target.value))
                }
              />
              <SuggestedMark show={action.suggested.task} />
            </div>
            <div>
              <Input
                aria-label={`Owner of task ${index + 1}`}
                placeholder="Owner"
                value={action.owner}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withActionEdited(value, index, "owner", event.target.value))
                }
              />
              <SuggestedMark show={action.suggested.owner} />
            </div>
            <div>
              <Input
                aria-label={`Due date of task ${index + 1}`}
                type="date"
                value={action.due}
                disabled={disabled}
                onChange={(event) =>
                  onChange(withActionEdited(value, index, "due", event.target.value))
                }
              />
              <SuggestedMark show={action.suggested.due} />
            </div>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              aria-label={`Remove task ${index + 1}`}
              disabled={disabled}
              onClick={() =>
                onChange({
                  ...value,
                  action_items: value.action_items.filter((_, i) => i !== index),
                })
              }
            >
              <X className="size-4" />
            </Button>
          </div>
        ))}
      </div>
    </div>
  )
}
