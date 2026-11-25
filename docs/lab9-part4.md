# Lab 9, Part 4 - the demos, without a Google Cloud bill

The "no GCP account" route replaces the three billed demos with the lab's Colab notebook
(*Lab 9. Part 4 without a Google Cloud bill*) and a Looker Studio dashboard, which needs only a
Google account. This file is the write-up; the links are the deliverable.

## What replaces what

| The billed demo | What was run instead | Where |
| --- | --- | --- |
| BigQuery: SQL over a public dataset, bytes processed noted | DuckDB over the same public dataset | notebook, section 3 |
| Vision API OCR | Tesseract and EasyOCR on the same image | notebook, section 4 |
| Document AI: a scanned invoice to structured output | Qwen3-VL 2B through Ollama: invoice to Markdown, then to JSON | notebook, sections 5-6 |
| Looker Studio chart over a BigQuery result | Looker Studio over `owid-co2-data.csv` | public dashboard |

## The links

- **Colab notebook** (own copy, outputs saved, shared *anyone with the link can view*):
  `TODO paste link`
- **Looker Studio dashboard** (public): `TODO paste link`

## The prompt used for invoice to JSON

Run on the Markdown from section 5 and on the invoice image, with the same model, and compared
against the expected answer in the notebook. Written out before the first run, because each
rerun of that cell costs about 3.5 minutes on the free CPU runtime.

```text
You are reading a single invoice. Return its contents as JSON and nothing else:
no commentary, no explanation, no Markdown code fence.

Use exactly this shape, with exactly these keys:

{
  "invoice_number": string,
  "invoice_date": string,          // ISO 8601, YYYY-MM-DD
  "due_date": string,              // ISO 8601, YYYY-MM-DD
  "currency": string,              // ISO 4217, e.g. "USD"
  "vendor": {"name": string, "address": string},
  "bill_to": {"name": string, "address": string},
  "line_items": [
    {"description": string, "quantity": number, "unit_price": number, "amount": number}
  ],
  "subtotal": number,
  "tax": number,
  "total": number
}

Rules:
- Copy values from the invoice. Do not infer, correct or complete anything.
- Any field that is not on the invoice is null. Never guess a value, and never drop a key.
- Numbers are JSON numbers: no currency symbols, no thousands separators, a dot for the
  decimal point. 1 234,50 EUR becomes 1234.50 with "currency": "EUR".
- Dates are YYYY-MM-DD. If a date is ambiguous, prefer the format the rest of the invoice uses.
- One object per line item, in the order they are printed. A line that is a subtotal, a tax
  line or a total is not a line item.
- Output JSON only, starting with { and ending with }.
```

## The three sentences

**Which input worked better, the Markdown or the image, and why.** `TODO after the run`

**How long sections 4 and 5 took, and on which hardware.** `TODO after the run - Colab free
CPU runtime (or T4), wall-clock from the cell timers`

**When I would pay for Document AI instead.** Document AI earns its $1.50 per 1,000 pages the
moment the documents stop being a demo: a known layout arriving in volume, where the processor
returns bounding boxes and confidence scores per field, is auditable, has an SLA, and does not
need a GPU of my own - whereas a 2B vision model on a free CPU runtime takes minutes a page and
gives no confidence at all. Below a few hundred pages a month, with a human reading every result
anyway, the open model is free and good enough.

## Link it back to Lab 8

Lab 8 queried payments with Athena over Glue tables in S3. On Google Cloud the same pipeline is
Cloud Storage for the raw files, Dataflow for the batch load (what the Glue crawler and the
Glue job did between them), BigQuery for the tables and the SQL, and Looker Studio for the chart
that Athena could not draw. What disappears is the Glue Data Catalog and the crawler: BigQuery
holds the schema itself, so there is no separate catalogue to keep in step with the data.
