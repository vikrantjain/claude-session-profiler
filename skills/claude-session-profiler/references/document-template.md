# Session Analysis Document Template

Read this file when you're ready to write the output document (after completing Steps 0-6).

## Building the Session Flow Diagram

Query the ordered events for the mermaid sequence diagram:

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  LogAttributes['event.sequence'] AS seq,
  Body AS event,
  LogAttributes['tool_name'] AS tool,
  LogAttributes['model'] AS model,
  toUInt64OrZero(LogAttributes['input_tokens']) AS input_tok,
  toUInt64OrZero(LogAttributes['output_tokens']) AS output_tok,
  Timestamp
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
ORDER BY Timestamp, toUInt32OrZero(seq)
FORMAT PrettyCompact
```

**Event → diagram mapping:**

- **Participants:** `User`, `Claude`, `Tools`, `Subagent` (if Agent calls exist)
- `user_prompt` → `User ->> Claude: <first ~60 chars>`
- `api_request` → `Claude ->> Claude: LLM call (<model>, <output_tok> out)`
- `tool_decision` → `Claude ->> Tools: <tool_name>()`
- `tool_result` → `Tools -->> Claude: <tool_name> (<result_size> bytes)`
- Agent `tool_result` → `Claude ->> Subagent: <description from tool_input>`
- `user_prompt` with `<task-notification>` → `Subagent -->> Claude: task complete`

Group by `prompt.id` — each prompt becomes a labeled block.

**Readability:**
- Collapse 3+ consecutive same-tool calls: `Tools -->> Claude: <tool_name> x5 (avg <size> bytes)`
- Sessions with 50+ events: detail first/last interaction, summarize middle as a note
- Subagent spawns: show spawn + completion as async block, don't inline internal events

## Document Structure

```markdown
# Session Analysis: <session_id_short>
**Date:** <timestamp range>
**Duration:** <minutes>
**Total Cost:** $<cost>

## Telemetry Level

- **Signals available:** <logs / logs + traces / metrics only>
- **Detail flags:** <which of OTEL_LOG_USER_PROMPTS, OTEL_LOG_TOOL_DETAILS, OTEL_LOG_TOOL_CONTENT, OTEL_TRACES_EXPORTER were active>

<If not fully configured:>
> **Note:** This session was recorded without full telemetry. <Describe what's missing
> and how it limits the analysis.> For the richest analysis, configure all flags — see
> `.claude-otel.env` or https://code.claude.com/docs/en/monitoring-usage

<If analysis was run outside the target project:>
> **Note:** This analysis is based on telemetry data only. Running the profiler from
> within the target project (`<detected path>`) would enable project-specific
> recommendations for CLAUDE.md optimization, permission tuning, and memory management.

## 1. Session Summary

<Stats table: duration, LLM calls, tool calls, tokens in/out, cache hit rate, cost by model, permission prompts. Numbers only — no interpretation.>

## 2. Session Flow

<Mermaid sequence diagram. See diagram construction rules above.>

## 3. Detailed Analysis

### 3.X <Finding Title>

**Evidence:**
<Raw telemetry data — actual query results, numbers, sequences, timestamps.>

**Analysis:**
<Interpretation. What pattern does this suggest? Be explicit about what you can see vs infer.>

**Confidence:** <high / medium / low>
<Why. High = data directly shows it. Low = inferring from structural patterns.>

**Assumption (if confidence is not high):**
<What your analysis rests on. E.g.: "Assumes the 8 sequential searches were independent.">

## 4. Recommendations

### 4.X <Recommendation Title>
**Based on:** Finding 3.X
**Category:** <Permission / Prompt strategy / Subagent strategy / Configuration / Workflow>
**Impact:** <high / medium / low> — <estimated savings>

**What to change:**
<Specific, actionable. Not "use better prompts" but "specify file path and section for edits.">

**Reasoning:**
<Why this addresses the finding. Restate assumptions so user sees them in context.>

## 5. Summary Table

| # | Finding | Confidence | Recommendation | Est. Impact |
|---|---------|-----------|----------------|-------------|
| 1 | ...     | high      | ...            | ~X tokens   |

<Closing note: invite user to flag wrong assumptions to improve future analysis.>
```

## Token Reporting in Section 1

- "Total input tokens" = `new_input + cache_read + cache_created` (the full context sent to the model)
- Show `cache_read` and `cache_created` as separate rows — they reveal cache efficiency
- Do NOT report the raw `input_tokens` telemetry field alone as "Total input tokens" — it excludes cached tokens and will be misleadingly small
