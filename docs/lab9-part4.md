# Lab 9, Part 4 - the demos, without a Google Cloud bill

The "no GCP account" route replaces the three billed demos with the lab's Colab notebook
(*Lab 9. Part 4 without a Google Cloud bill*) and a Looker Studio dashboard, which needs only a
Google account. This file is the write-up; the links are the deliverable.

## What replaces what

| The billed demo | What was run instead | Where |
| --- | --- | --- |
| BigQuery: SQL over a public dataset, bytes processed noted | DuckDB over the same public dataset | notebook, section 1 |
| Vision API OCR | Tesseract and EasyOCR on the same image | notebook, section 3 |
| Document AI: a scanned invoice to structured output | Qwen3-VL 2B through Ollama: invoice to Markdown, then to JSON | notebook, sections 4-5 |
| Looker Studio chart over a BigQuery result | Looker Studio over `owid-co2-data.csv` | public dashboard |

## The links

- **Colab notebook** (own copy, outputs saved, shared *anyone with the link can view*):
  `TODO paste link`
- **Looker Studio dashboard** (public): `TODO paste link`

## The prompt used for invoice to JSON

Section 5 of the notebook fixes the *shape* of the answer with a JSON schema (`invoice_number`,
`date`, `due_date`, `seller`, `buyer`, `items` of `description`/`qty`/`unit_price`, `subtotal`,
`vat`, `total`) and leaves the *content* to the prompt. This is what went into `MY_PROMPT`, run
once on the Markdown from section 4 and once on the image, and scored against the notebook's
ground truth. It was written before the first run, because each run of that cell costs about
3.5 minutes on the free CPU runtime.

```text
Read the invoice and return its fields. Copy what is printed; do not calculate,
correct or complete anything.

invoice_number  the invoice number, exactly as printed (e.g. INV-2026-0417).
date            the invoice date as printed, format YYYY-MM-DD.
due_date        the due date, format YYYY-MM-DD.
seller          the party the invoice is FROM: its name and its address in one
                string, separated by a comma, exactly as printed.
buyer           the party the invoice is BILLED TO: name and address in one
                string, separated by a comma, exactly as printed.
items           one entry per row of the line-item table, in the printed order.
                description is the row's text, copied word for word.
                qty is a whole number. unit_price is the price of one unit.
                Subtotal, VAT and Total are not items: never put them here.
subtotal        the printed subtotal.
vat             the printed VAT amount, not the percentage.
total           the printed total.

All amounts are plain numbers: no currency symbol, no thousands separator, a dot
for the decimal point. A field that is not on the invoice is null, and no key is
ever left out.
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
