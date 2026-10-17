-- Is agenda-v2 better than agenda-v1? Answered from saved data, with no parse replayed.
--
-- Every saved agenda keeps both halves of the pair: `ai_suggestion` (what the model proposed,
-- verbatim) and `agenda` (what the user kept after editing it). The measure is how much of the
-- suggestion survived - per field, because the interesting case is the mixed one, where the
-- topic was right and the owner was not.
--
-- Run it against the meetings database (psql, or `make aws-backend-sql` if that ever exists).

-- 1. The headline: what share of suggested fields the user left alone, per prompt version.
--    `kept_field_rate` near 1.0 means the form was right as it arrived.
WITH suggested AS (
    SELECT
        m.id,
        m.ai_prompt_version,
        m.ai_model,
        item.ordinality AS position,
        item.value ->> 'topic' AS topic,
        item.value ->> 'owner' AS owner,
        item.value ->> 'minutes' AS minutes
    FROM meetings m
    CROSS JOIN LATERAL jsonb_array_elements(m.ai_suggestion -> 'items')
        WITH ORDINALITY AS item (value, ordinality)
    WHERE m.ai_suggestion IS NOT NULL
),
kept AS (
    SELECT
        m.id,
        item.ordinality AS position,
        item.value ->> 'topic' AS topic,
        item.value ->> 'owner' AS owner,
        item.value ->> 'minutes' AS minutes
    FROM meetings m
    CROSS JOIN LATERAL jsonb_array_elements(m.agenda -> 'items')
        WITH ORDINALITY AS item (value, ordinality)
    WHERE m.agenda IS NOT NULL
),
-- One row per suggested field, with whether it survived. Three fields per agenda item, compared
-- at the same position: a reordered agenda counts as edited, which is the honest reading.
fields AS (
    SELECT s.ai_prompt_version, 'topic' AS field, (k.topic IS NOT DISTINCT FROM s.topic) AS survived
    FROM suggested s LEFT JOIN kept k ON k.id = s.id AND k.position = s.position
    WHERE s.topic IS NOT NULL
    UNION ALL
    SELECT s.ai_prompt_version, 'owner', (k.owner IS NOT DISTINCT FROM s.owner)
    FROM suggested s LEFT JOIN kept k ON k.id = s.id AND k.position = s.position
    WHERE s.owner IS NOT NULL
    UNION ALL
    SELECT s.ai_prompt_version, 'minutes', (k.minutes IS NOT DISTINCT FROM s.minutes)
    FROM suggested s LEFT JOIN kept k ON k.id = s.id AND k.position = s.position
    WHERE s.minutes IS NOT NULL
)
SELECT
    ai_prompt_version,
    count(*) AS suggested_fields,
    count(*) FILTER (WHERE survived) AS kept_fields,
    round(count(*) FILTER (WHERE survived)::numeric / count(*), 3) AS kept_field_rate
FROM fields
GROUP BY ai_prompt_version
ORDER BY ai_prompt_version;

-- 2. The same, per field, which is where a prompt change usually shows up: v1's weak spot is
--    dates and owners, not topics, and an average over all fields hides that.
WITH suggested AS (
    SELECT m.id, m.ai_prompt_version, item.ordinality AS position,
           item.value ->> 'topic' AS topic, item.value ->> 'owner' AS owner,
           item.value ->> 'minutes' AS minutes
    FROM meetings m
    CROSS JOIN LATERAL jsonb_array_elements(m.ai_suggestion -> 'items')
        WITH ORDINALITY AS item (value, ordinality)
    WHERE m.ai_suggestion IS NOT NULL
),
kept AS (
    SELECT m.id, item.ordinality AS position,
           item.value ->> 'topic' AS topic, item.value ->> 'owner' AS owner,
           item.value ->> 'minutes' AS minutes
    FROM meetings m
    CROSS JOIN LATERAL jsonb_array_elements(m.agenda -> 'items')
        WITH ORDINALITY AS item (value, ordinality)
    WHERE m.agenda IS NOT NULL
)
SELECT
    s.ai_prompt_version,
    count(*) FILTER (WHERE s.topic IS NOT NULL) AS topics,
    round(avg((k.topic IS NOT DISTINCT FROM s.topic)::int) FILTER (WHERE s.topic IS NOT NULL), 3) AS topic_kept,
    round(avg((k.owner IS NOT DISTINCT FROM s.owner)::int) FILTER (WHERE s.owner IS NOT NULL), 3) AS owner_kept,
    round(avg((k.minutes IS NOT DISTINCT FROM s.minutes)::int) FILTER (WHERE s.minutes IS NOT NULL), 3) AS minutes_kept
FROM suggested s
LEFT JOIN kept k ON k.id = s.id AND k.position = s.position
GROUP BY s.ai_prompt_version
ORDER BY s.ai_prompt_version;

-- 3. Two counts that keep the headline honest. A prompt that proposes less gets a better keep
--    rate for free, and a prompt that makes the user type the agenda themselves is not better.
SELECT
    ai_prompt_version,
    count(*) AS agendas,
    round(avg(jsonb_array_length(ai_suggestion -> 'items')), 2) AS items_suggested,
    round(avg(jsonb_array_length(agenda -> 'items')), 2) AS items_saved,
    count(*) FILTER (WHERE jsonb_array_length(agenda -> 'items') = 0) AS saved_empty
FROM meetings
WHERE ai_suggestion IS NOT NULL
GROUP BY ai_prompt_version
ORDER BY ai_prompt_version;
