---
name: claude-session-profiler
disable-model-invocation: true
description: >
  Profile and analyze Claude Code session telemetry from ClickStack (ClickHouse).
  Produces a detailed analysis document covering token/cost breakdown, tool usage,
  permission friction, prompt quality assessment, subagent assessment, and optimization
  recommendations — including how user prompts contributed to inefficiency.
---

# Claude Session Profiler

You profile Claude Code telemetry stored in ClickStack (ClickHouse) to understand session behavior and identify optimization opportunities for reducing token usage, round-trips, and costs. This includes evaluating how user prompts and requirements contributed to session efficiency — whether vague prompts drove unnecessary exploration, compound requests prevented parallelism, or missing context forced the agent to search for what the user already knew. You produce a detailed analysis document that traces every recommendation back to specific telemetry evidence, states your reasoning and confidence level, and flags assumptions — so the user can validate your conclusions and provide corrections that improve future analysis.

## Connection

Before running any queries, check if `.claude/claude-profiler.local.md` exists and read the `clickhouse_url` from its YAML frontmatter:

```markdown
---
clickhouse_url: http://your-host:8123
---
```

If the file is absent or `clickhouse_url` is not set, **stop and ask the user** for the ClickHouse HTTP REST API URL including host and port (e.g. `http://myserver:8123`). Do not assume any default or attempt discovery. Once provided, offer to save it to `.claude/claude-profiler.local.md`.

Query using:
```bash
curl -s --get "<CLICKHOUSE_URL>/" --data-urlencode "query=<SQL>"
```

## Telemetry Configuration

Analysis depth depends on what telemetry was enabled. Step 0 detects the level automatically. These environment variables can be set however the user prefers — shell profile, project-level env file, direnv, etc. Full documentation: https://code.claude.com/docs/en/monitoring-usage

Key flags that unlock deeper analysis (each builds on the previous):
- `OTEL_LOG_USER_PROMPTS=1` + `OTEL_LOG_TOOL_DETAILS=1` → user prompt text, tool input JSON, result sizes (minimum for meaningful profiling)
- `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + `OTEL_TRACES_EXPORTER=otlp` → span hierarchy, execution vs permission time breakdown
- `OTEL_LOG_TOOL_CONTENT=1` → full tool I/O content in trace spans (60KB limit, generates significant data)

If the session had incomplete configuration, note what's missing in the report and recommend upgrading.

## Available Tables

| Table | Purpose | Key columns |
|---|---|---|
| `otel_logs` | Log events: API requests, tool results, user prompts, tool decisions | `Body` (event name), `LogAttributes` (map), `ServiceName` |
| `otel_traces` | Spans: interactions, LLM calls, tool usage, execution, permission prompts | `SpanName`, `SpanAttributes` (map), `ServiceName` |
| `otel_metrics_sum` | Counter metrics: tokens, cost, sessions | `MetricName`, `Attributes` (map), `Value` |
| `otel_metrics_gauge` | Gauge metrics | `MetricName`, `Attributes` (map), `Value` |
| `otel_metrics_histogram` | Histogram metrics | `MetricName`, `Attributes` (map) |

Always filter with `ServiceName = 'claude-code'` to exclude ClickStack's own telemetry.

Logs are the primary data source — they're available at all telemetry levels and contain the richest event data. Traces provide supplementary structural information (span hierarchy, parent-child relationships) when available. The workflow below uses logs as the primary source with trace-based enrichment where traces exist.

## What's In the Telemetry (and What Isn't)

The telemetry captures structure and metadata — not full content. Understanding these boundaries avoids querying for data that doesn't exist.

**Log attributes by event type (primary data source):**

| Event (`Body`) | Key attributes in `LogAttributes` |
|---|---|
| `claude_code.user_prompt` | `prompt` (full text, requires `OTEL_LOG_USER_PROMPTS=1`), `prompt_length`, `prompt.id` |
| `claude_code.tool_result` | `tool_name`, `tool_input` (JSON, requires `OTEL_LOG_TOOL_DETAILS=1`; individual values truncated at 512 chars, total ~4KB), `tool_parameters` (JSON with Bash commands, MCP/skill names, requires `OTEL_LOG_TOOL_DETAILS=1`), `tool_result_size_bytes`, `duration_ms`, `success`, `decision_type` (accept/reject), `decision_source`, `prompt.id` |
| `claude_code.tool_decision` | `tool_name`, `decision` (accept/reject), `source` (config/hook/user_permanent/user_temporary/user_abort/user_reject), `prompt.id` (sometimes absent) |
| `claude_code.api_request` | `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `duration_ms`, `speed` (fast/normal), `prompt.id` |
| `claude_code.api_error` | `model`, `error`, `status_code`, `duration_ms`, `attempt`, `speed` (fast/normal), `prompt.id` |

All log events have `session.id` and `event.sequence` for ordering.

Note: `prompt.id` is present on most events but occasionally absent on some `tool_decision` events. When joining by `prompt.id`, use it for grouping but don't rely on it being present on every row.

Note: `tool_input` values are truncated — individual values at 512 chars, total payload at ~4KB. For long Bash commands or large Agent prompts, you may see truncated content. The `tool_parameters` attribute is a separate field with Bash command details, MCP server/tool names, and skill names.

**Trace attributes (when traces are available):**

| Span (`SpanName`) | Key attributes in `SpanAttributes` |
|---|---|
| `claude_code.interaction` | `session.id`, `interaction.sequence`, `user_prompt` |
| `claude_code.llm_request` | `session.id`, `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens` |
| `claude_code.tool` | `session.id`, `tool_name`, `duration_ms` |
| `claude_code.tool.execution` | `duration_ms` (child of `claude_code.tool`) |
| `claude_code.tool.blocked_on_user` | `duration_ms` (child of `claude_code.tool`) |

Traces add span hierarchy: `claude_code.tool` spans have child spans for execution time and permission wait time, joined via `ParentSpanId`/`SpanId`/`TraceId`.

**Not available in logs — don't query these from `otel_logs`:**

- **Tool result content** — logs have `tool_result_size_bytes` (how big the result was) but not the actual output. You cannot read what a Grep found or what a Bash command printed from logs alone.
- **LLM prompt/completion text** — you get token counts and cost per API call, but not the messages sent to or received from the model.

**Conditionally available in traces (Level 3 with `OTEL_LOG_TOOL_CONTENT=1`):**

- **Tool input and output content** — when `OTEL_LOG_TOOL_CONTENT=1` is set, trace span events include full tool input and output content (truncated at 60KB per span). This means you *can* read file contents, Bash output, and search results from traces — but only if this flag was enabled. Check for this in Step 0 before attempting content-level analysis from traces.

**What this means for analysis:** rely on structural signals — tool call sequences, token counts, timing, input token growth, tool_input parameters — rather than content inspection. For example, you can tell that a Grep was run for pattern `"handleAuth"` in `src/` (from `tool_input`), and that the result was 15KB (from `tool_result_size_bytes`), but you can't see the matching lines. You can infer relatedness between searches from their `tool_input` parameters (similar patterns, overlapping paths) rather than from their results.

## Input

The user provides one of:
- **Session ID** — a UUID like `87d3f3ba-ce6b-44ae-b8fd-557d2973c3c1` → proceed directly to analysis
- **"last session"** → run session discovery, take the first result
- **"recent sessions"** → run session discovery, present the list for the user to pick one
- **Time range** — e.g., "last 2 hours", "today" → run session discovery with time filter; if multiple sessions match, present the list and ask which one to analyze
- **"all sessions"** or **"compare sessions"** → run session discovery and present the list; the user may want one profiled, several compared, or a summary

**This skill profiles one session at a time.** If the user's input resolves to multiple sessions (time range, "today", "recent"), always show the session list with key stats (duration, cost, LLM calls) and ask the user to pick one. Don't silently pick for them — session choice matters for the analysis.

If the user wants multiple sessions profiled, they can either:
- Pick them one at a time across separate invocations
- Ask you to spawn parallel subagents, one per session (each running this same skill independently)

## Step 0: Resolve Connection & Check Data Availability

Resolve the ClickHouse URL per the Connection section above before running any queries. Then check what signals exist:

```sql
SELECT 'logs' AS signal, count() AS rows FROM otel_logs WHERE ServiceName = 'claude-code'
UNION ALL
SELECT 'traces', count() FROM otel_traces WHERE ServiceName = 'claude-code'
UNION ALL
SELECT 'metrics', count() FROM otel_metrics_sum WHERE ServiceName = 'claude-code'
FORMAT PrettyCompact
```

Then check the detail level of logs and whether API errors exist:

```sql
SELECT
  countIf(Body = 'claude_code.user_prompt' AND LogAttributes['prompt'] != '') AS has_prompts,
  countIf(Body = 'claude_code.tool_result' AND LogAttributes['tool_input'] != '') AS has_tool_input,
  countIf(Body = 'claude_code.tool_result' AND LogAttributes['tool_result_size_bytes'] != '') AS has_result_size,
  countIf(Body = 'claude_code.api_error') AS api_errors
FROM otel_logs
WHERE ServiceName = 'claude-code'
FORMAT PrettyCompact
```

Record the telemetry level (1/2/3) for the report disclaimer. If `api_errors > 0`, include API error analysis in Step 5. If logs are empty, you can only do aggregate metrics analysis — tell the user and suggest enabling logs.

Refer to the official telemetry documentation at https://code.claude.com/docs/en/monitoring-usage for the full list of available attributes and configuration options.

## Session Discovery

When the user doesn't provide a specific session ID, list recent sessions and present them to the user. If only one session matches their criteria (e.g., "last session"), proceed directly. If multiple match, show the list and ask which one to profile:

```sql
SELECT
  LogAttributes['session.id'] AS session_id,
  min(Timestamp) AS started,
  max(Timestamp) AS ended,
  dateDiff('minute', min(Timestamp), max(Timestamp)) AS duration_min,
  countIf(Body = 'claude_code.api_request') AS llm_calls,
  countIf(Body = 'claude_code.tool_result') AS tool_calls,
  countIf(Body = 'claude_code.user_prompt') AS user_prompts,
  countIf(Body = 'claude_code.tool_decision' AND LogAttributes['decision'] != 'accept') AS permission_prompts,
  sum(toFloat64OrZero(LogAttributes['cost_usd'])) AS cost_usd
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND Timestamp > now() - INTERVAL 7 DAY
GROUP BY session_id
ORDER BY started DESC
LIMIT 20
FORMAT PrettyCompact
```

For time-based filters, add to the WHERE clause:
- "last session" → take the first result, proceed directly
- "today" → `AND toDate(Timestamp) = today()`
- "last 2 hours" → `AND Timestamp > now() - INTERVAL 2 HOUR`
- Specific range → `AND Timestamp BETWEEN '<start>' AND '<end>'`

If the filtered query returns multiple sessions, present the list and ask the user to pick one before proceeding.

**Note:** If the user says "last session" or "recent sessions", the current (active) session may appear as the most recent result. It will have an open-ended time range and incomplete data. Either skip it automatically (take the second result for "last session") or flag it to the user: "The first result appears to be your current active session — would you like to analyze the second one instead?"

## Analysis Workflow

Work through these steps to collect evidence for the analysis document. Each step feeds into Sections 3 and 4 of the final document. All queries use logs as the primary source; trace-based enrichment queries are marked with **(traces)** — run them only if Step 0 confirmed traces are available.

### Step 1: Token and Cost Analysis (feeds → Section 1, 3)

```sql
SELECT
  LogAttributes['model'] AS model,
  count() AS api_calls,
  sum(toFloat64OrZero(LogAttributes['cost_usd'])) AS total_cost_usd,
  sum(toUInt64OrZero(LogAttributes['input_tokens'])) AS new_input,
  sum(toUInt64OrZero(LogAttributes['cache_read_tokens'])) AS cache_read,
  sum(toUInt64OrZero(LogAttributes['cache_creation_tokens'])) AS cache_created,
  sum(toUInt64OrZero(LogAttributes['input_tokens']))
    + sum(toUInt64OrZero(LogAttributes['cache_read_tokens']))
    + sum(toUInt64OrZero(LogAttributes['cache_creation_tokens'])) AS total_context,
  sum(toUInt64OrZero(LogAttributes['output_tokens'])) AS output_tokens
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_request'
GROUP BY model
ORDER BY total_cost_usd DESC
FORMAT PrettyCompact
```

**Understanding the token columns:** The Anthropic API splits input tokens into three non-overlapping categories:
- `new_input` (`input_tokens` in telemetry) — tokens not served from cache and not written to cache; usually very small
- `cache_read` — tokens served from prompt cache (cheapest)
- `cache_created` — tokens written to cache this request (most expensive input tier)
- `total_context` = `new_input + cache_read + cache_created` — the actual total tokens sent to the model

In the summary table, report `total_context` as "Total input tokens", not `new_input`. The `cost_usd` attribute is pre-computed by Claude Code — use it directly rather than hardcoding model rates.

### Step 2: Tool Usage Breakdown (feeds → Section 1, 3)

**From logs (always available):**

```sql
SELECT
  LogAttributes['tool_name'] AS tool,
  count() AS uses,
  avg(toUInt64OrZero(LogAttributes['duration_ms'])) AS avg_duration_ms,
  max(toUInt64OrZero(LogAttributes['duration_ms'])) AS max_duration_ms,
  countIf(LogAttributes['success'] = 'false') AS failures,
  avg(toUInt64OrZero(LogAttributes['tool_result_size_bytes'])) AS avg_result_bytes
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.tool_result'
GROUP BY tool
ORDER BY uses DESC
FORMAT PrettyCompact
```

**Permission friction from logs:**

```sql
SELECT
  LogAttributes['tool_name'] AS tool,
  countIf(LogAttributes['decision'] = 'accept') AS accepted,
  countIf(LogAttributes['decision'] != 'accept') AS blocked,
  groupArrayIf(LogAttributes['source'], LogAttributes['decision'] != 'accept') AS block_sources
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.tool_decision'
GROUP BY tool
HAVING blocked > 0
ORDER BY blocked DESC
FORMAT PrettyCompact
```

**(traces) Execution vs permission time breakdown:**

If traces are available, this join separates actual execution time from permission wait time per tool:

```sql
SELECT
  t.SpanAttributes['tool_name'] AS tool,
  count(*) AS uses,
  avg(toUInt64OrZero(t.SpanAttributes['duration_ms'])) AS avg_total_ms,
  avg(toUInt64OrZero(e.SpanAttributes['duration_ms'])) AS avg_exec_ms,
  avg(toUInt64OrZero(b.SpanAttributes['duration_ms'])) AS avg_blocked_ms,
  countIf(toUInt64OrZero(b.SpanAttributes['duration_ms']) > 0) AS times_blocked
FROM otel_traces t
LEFT JOIN otel_traces e
  ON e.ParentSpanId = t.SpanId AND e.TraceId = t.TraceId
  AND e.SpanName = 'claude_code.tool.execution'
LEFT JOIN otel_traces b
  ON b.ParentSpanId = t.SpanId AND b.TraceId = t.TraceId
  AND b.SpanName = 'claude_code.tool.blocked_on_user'
WHERE t.ServiceName = 'claude-code'
  AND t.SpanName = 'claude_code.tool'
  AND t.SpanAttributes['session.id'] = '<SESSION_ID>'
GROUP BY tool
ORDER BY times_blocked DESC, avg_total_ms DESC
FORMAT PrettyCompact
```

This reveals per tool:
- **avg_exec_ms** — how long the tool actually takes to run
- **avg_blocked_ms** — how long the user was prompted for permission
- **the gap** (`avg_total_ms - avg_exec_ms - avg_blocked_ms`) — framework overhead

Without traces, you still get total `duration_ms` per tool from logs and blocked/allowed counts from `tool_decision` events — you just can't separate execution time from permission time within a single tool call.

### Step 3: Interaction Flow (feeds → Section 1, 2, 3)

**From logs (always available):**

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  min(Timestamp) AS started,
  substring(
    argMinIf(LogAttributes['prompt'], Timestamp, Body = 'claude_code.user_prompt'), 1, 120
  ) AS user_prompt,
  countIf(Body = 'claude_code.api_request') AS llm_calls,
  countIf(Body = 'claude_code.tool_result') AS tool_calls,
  sum(toFloat64OrZero(LogAttributes['cost_usd'])) AS cost_usd,
  sum(toUInt64OrZero(LogAttributes['input_tokens'])) AS input_tokens,
  sum(toUInt64OrZero(LogAttributes['output_tokens'])) AS output_tokens
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND LogAttributes['prompt.id'] != ''
GROUP BY prompt_id
ORDER BY started
FORMAT PrettyCompact
```

This gives you the cost and activity breakdown per interaction (prompt). Map each prompt to what the user asked and how much work it generated.

**Prompt quality assessment (when `OTEL_LOG_USER_PROMPTS=1` is active):**

If Step 0 confirmed prompt text is available, enrich the interaction flow with a prompt effectiveness analysis. This isn't a separate step — it's understanding *why* each interaction cost what it did, which is inseparable from understanding the interaction flow itself.

Pull full prompt text for all user prompts (excluding subagent task-notifications):

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  LogAttributes['prompt'] AS prompt_text,
  length(LogAttributes['prompt']) AS prompt_length,
  Timestamp
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.user_prompt'
  AND LogAttributes['prompt'] NOT LIKE '%<task-notification>%'
ORDER BY Timestamp
FORMAT PrettyCompact
```

Also pull the per-prompt tool breakdown to see the search-vs-action split for each interaction:

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  countIf(LogAttributes['tool_name'] IN ('Grep', 'Glob')) AS search_calls,
  countIf(LogAttributes['tool_name'] = 'Read') AS read_calls,
  countIf(LogAttributes['tool_name'] IN ('Edit', 'Write')) AS edit_calls,
  countIf(LogAttributes['tool_name'] = 'Bash') AS bash_calls,
  countIf(Body = 'claude_code.api_request') AS llm_calls,
  sum(toFloat64OrZero(LogAttributes['cost_usd'])) AS cost_usd
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body IN ('claude_code.tool_result', 'claude_code.api_request')
  AND LogAttributes['prompt.id'] != ''
GROUP BY prompt_id
ORDER BY search_calls DESC
FORMAT PrettyCompact
```

Cross-reference the prompt text with the cost/activity data from the per-prompt query above. For each interaction, you now have: what the user said, how much the agent spent, and how the agent allocated that effort between searching and acting. This data feeds directly into Step 5's problem identification — when Step 5 flags an expensive interaction, the prompt text and search-vs-action ratio are the first place to look for the root cause.

**What to capture per interaction for Step 5:**
- Prompt specificity: does it name files, functions, error messages, or is it abstract?
- Prompt scope: bounded ("update retry logic in `client.ts`") vs open-ended ("make the API more robust")?
- Search-to-action ratio: high search calls relative to edits suggests the agent had to discover what the prompt could have specified
- Correction patterns: sequential prompts where later ones narrow scope or redirect ("fix the tests" → "the auth tests" → "specifically `test_login_flow`")
- Compound requests: a single prompt that generated work across unrelated code areas

Don't interpret these patterns here — just collect and annotate the interaction flow data. Step 5 uses this to trace problems to their root cause.

**(traces) Interaction sequence with span-level prompts:**

```sql
SELECT
  SpanAttributes['interaction.sequence'] AS seq,
  substring(SpanAttributes['user_prompt'], 1, 120) AS prompt
FROM otel_traces
WHERE ServiceName = 'claude-code'
  AND SpanName = 'claude_code.interaction'
  AND SpanAttributes['session.id'] = '<SESSION_ID>'
ORDER BY toUInt32OrZero(seq)
FORMAT PrettyCompact
```

If traces have `user_prompt` in span attributes, this provides a cleaner interaction sequence. If the attribute is empty, fall back to the logs-based query above.

### Step 4: Subagent Analysis (feeds → Section 3)

Subagent calls are identified by `tool_name = 'Agent'` in logs. The `tool_input` JSON on Agent tool_result events contains `description`, `subagent_type`, and `prompt`.

**Detect subagent usage:**

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  count() AS agent_spawns,
  groupArray(substring(LogAttributes['tool_input'], 1, 200)) AS agent_inputs
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.tool_result'
  AND LogAttributes['tool_name'] = 'Agent'
GROUP BY prompt_id
FORMAT PrettyCompact
```

If no results, skip the rest of this step — no subagents were used.

**Understand the subagent event lifecycle:**

Subagent telemetry spans three phases, each with a different `prompt.id`:

1. **Spawn prompt** — the prompt where the user's message was processed and `Agent` tools were called. Subagent LLM calls and tool calls are interleaved here within the same `prompt.id` and `session.id` as the main agent. There is no attribute to distinguish which events belong to the main agent vs subagents, or to distinguish between multiple parallel subagents.

2. **Completion prompts** — when each background subagent finishes, a `<task-notification>` is injected as a new `user_prompt` event with its own `prompt.id`. The notification XML contains a `<task-id>` that can be correlated back to the Agent `tool_input` JSON from the detection query above (which has the `description` and `subagent_type`). The main agent then processes this notification (usually 1-2 LLM calls).

3. **Follow-up prompts** — the main agent continues with subsequent user messages.

**Identify subagent completion prompts:**

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  substring(LogAttributes['prompt'], 1, 500) AS prompt_text,
  Timestamp
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.user_prompt'
  AND LogAttributes['prompt'] LIKE '%<task-notification>%'
ORDER BY Timestamp
FORMAT PrettyCompact
```

The `prompt_text` contains `<task-id>` which links back to a specific Agent spawn. This is the only reliable way to correlate a subagent's completion with its spawn.

**Break down cost per prompt (for subagent cost attribution):**

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  LogAttributes['model'] AS model,
  count() AS api_calls,
  sum(toUInt64OrZero(LogAttributes['input_tokens'])) AS input_tokens,
  sum(toUInt64OrZero(LogAttributes['output_tokens'])) AS output_tokens,
  sum(toFloat64OrZero(LogAttributes['cost_usd'])) AS cost_usd
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_request'
GROUP BY prompt_id, model
ORDER BY prompt_id, model
FORMAT PrettyCompact
```

Cross-reference with the subagent completion prompts above. Completion prompts (those with `<task-notification>` user_prompt) represent the cost of the main agent *processing* the subagent result, not the subagent's own work.

**Reconstruct the full timeline:**

```sql
SELECT
  LogAttributes['event.sequence'] AS seq,
  Body AS event,
  LogAttributes['tool_name'] AS tool,
  LogAttributes['model'] AS model,
  toUInt64OrZero(LogAttributes['output_tokens']) AS output_tok,
  LogAttributes['prompt.id'] AS prompt_id,
  Timestamp
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND LogAttributes['prompt.id'] IN ('<SPAWN_PROMPT_ID>', '<COMPLETION_PROMPT_ID_1>', '<COMPLETION_PROMPT_ID_2>')
ORDER BY toUInt32OrZero(seq)
FORMAT PrettyCompact
```

Use the spawn prompt ID and all related completion prompt IDs to see the full subagent lifecycle across prompts.

**Attribution limitations:**

- Within the spawn prompt, all subagent LLM calls and tool calls are interleaved with the main agent's own calls. There is no per-agent identifier — you cannot determine which calls came from which subagent, or separate main agent calls from subagent calls, even when the models differ.
- You **can** count how many subagents were spawned (count `Agent` tool_result events in the spawn prompt).
- You **can** identify what each subagent was asked to do (parse `tool_input` JSON from Agent `tool_result` logs for `description` and `subagent_type`).
- You **can** identify when each subagent completed (match `<task-id>` in completion prompts to Agent tool_input).
- You **cannot** attribute individual LLM or tool calls to a specific subagent within the spawn prompt.
- For total subagent cost estimation, sum all api_request costs in the spawn prompt and subtract the expected main agent calls (typically the LLM calls that happened before the first Agent spawn and after the last subagent event). This is approximate.

### Step 5: Identify Problems (feeds → Section 3, 4)

Look for these patterns and flag them. Each becomes a finding in Section 3 of the document — include the evidence, your analysis, confidence level, and any assumptions.

**API errors (if detected in Step 0):**

```sql
SELECT
  LogAttributes['model'] AS model,
  LogAttributes['error'] AS error,
  LogAttributes['status_code'] AS status_code,
  toUInt32OrZero(LogAttributes['attempt']) AS attempt,
  LogAttributes['duration_ms'] AS duration_ms,
  LogAttributes['prompt.id'] AS prompt_id,
  Timestamp
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_error'
ORDER BY Timestamp
FORMAT PrettyCompact
```

Look for: rate limit errors (status 429), server errors (5xx), retries (`attempt` > 1), and errors concentrated in specific prompts. API errors add latency and can cause the model to retry or change approach.

**Too many LLM round-trips per interaction — trace to root cause:**

Simple tasks (file edit, single question) should need 2-3 LLM calls. More than 5 calls for a simple task indicates a problem — but the problem has different root causes that require different recommendations. Use the prompt text and search-vs-action data collected in Step 3 to distinguish:

- *Vague or underspecified prompt* — The prompt lacked specifics (no file paths, function names, or error messages) and the agent spent most of its round-trips on search calls (high search-to-action ratio from Step 3). The user likely had context they didn't provide. **Recommendation category: Prompt quality** — suggest a rewritten prompt that includes the specifics the agent eventually discovered, with an estimate of the savings.

- *Overly broad scope* — The prompt was open-ended ("make the API more robust", "improve test coverage") forcing the agent to decide *what* to do before *how* to do it. This shows up as high LLM calls with many different tool targets across unrelated directories. **Recommendation category: Prompt quality** — suggest breaking into bounded subtasks or providing acceptance criteria.

- *Compound request* — A single prompt contained multiple unrelated tasks ("fix the auth bug and also update the README and add a test for the billing module"). The agent handled them sequentially when they could have been separate prompts or parallel subagents. Cross-reference `tool_input` file paths — if they span unrelated directories within one prompt, check if the prompt text contained multiple requests. **Recommendation category: Prompt quality** — suggest splitting into separate prompts or explicit subagent delegation.

- *Correction/redirection across prompts* — Sequential prompts where the user progressively narrows scope: "fix the tests" → "the auth tests" → "specifically `test_login_flow`". Each redirect wasted the agent's prior exploration. **Recommendation category: Prompt quality** — show the escalating sequence and suggest the final, specific version as the starting point.

- *Agent hesitation (not a prompt issue)* — The prompt was specific enough but the agent still took many round-trips, visible as read-after-write patterns, low-output-token LLM calls, or repeated searches with slight variations. **Recommendation category: Workflow/Configuration** — this is a model behavior issue, not a user prompt issue.

When prompt text is not available (no `OTEL_LOG_USER_PROMPTS=1`), you can still detect the structural patterns (search-heavy prompts, correction sequences, compound work) — but you can't confirm whether the prompt itself was the root cause. Note this limitation and present findings as "likely prompt-related" at lower confidence.

For each prompt-quality finding, generate a concrete rewritten prompt that includes the specifics the agent eventually discovered — but only information the user likely had at the time. Estimate the impact: "Providing the file path directly would have eliminated ~N search calls and ~M LLM rounds, saving ~Xk input tokens (~$Y)."

**What NOT to flag as a prompt quality issue:**
- Prompts for genuinely exploratory tasks ("help me understand how the auth system works") — exploration is the point
- Short conversational follow-ups ("yes", "looks good", "go ahead") — normal interaction
- Prompts where the agent was efficient despite brevity — a short prompt that led to 2 LLM calls and 1 edit is fine
- Users working in unfamiliar codebases — if the user couldn't have known the file paths, the exploration was necessary

**High permission friction:**
- Tools with many blocked decisions (from the permission friction query in Step 2)
- With traces: tools with high `avg_blocked_ms` or many `times_blocked`
- Recommend adding specific allow rules for frequently approved tools

**Slow tool executions:**
- Tools with high `avg_duration_ms` or `max_duration_ms` (from the tool usage query in Step 2)
- Look for Bash executions > 5 seconds — the command might be optimizable

**Read-after-write patterns:**

Detect Edit → Read → Edit sequences on the same file — suggests the model wasn't confident and wasted at least 1 LLM round-trip:

```sql
SELECT
  a.LogAttributes['event.sequence'] AS edit1_seq,
  b.LogAttributes['event.sequence'] AS read_seq,
  c.LogAttributes['event.sequence'] AS edit2_seq,
  JSONExtractString(a.LogAttributes['tool_input'], 'file_path') AS file_path
FROM otel_logs a
JOIN otel_logs b ON b.LogAttributes['session.id'] = a.LogAttributes['session.id']
  AND b.Body = 'claude_code.tool_result'
  AND b.LogAttributes['tool_name'] = 'Read'
  AND toUInt32OrZero(b.LogAttributes['event.sequence']) > toUInt32OrZero(a.LogAttributes['event.sequence'])
JOIN otel_logs c ON c.LogAttributes['session.id'] = a.LogAttributes['session.id']
  AND c.Body = 'claude_code.tool_result'
  AND c.LogAttributes['tool_name'] = 'Edit'
  AND toUInt32OrZero(c.LogAttributes['event.sequence']) > toUInt32OrZero(b.LogAttributes['event.sequence'])
WHERE a.ServiceName = 'claude-code'
  AND a.LogAttributes['session.id'] = '<SESSION_ID>'
  AND a.Body = 'claude_code.tool_result'
  AND a.LogAttributes['tool_name'] = 'Edit'
  AND JSONExtractString(b.LogAttributes['tool_input'], 'file_path') = JSONExtractString(a.LogAttributes['tool_input'], 'file_path')
  AND JSONExtractString(c.LogAttributes['tool_input'], 'file_path') = JSONExtractString(a.LogAttributes['tool_input'], 'file_path')
  AND toUInt32OrZero(c.LogAttributes['event.sequence']) - toUInt32OrZero(a.LogAttributes['event.sequence']) <= 6
FORMAT PrettyCompact
```

The sequence gap filter (`<= 6`) keeps it focused on tight Edit→Read→Edit patterns rather than matching unrelated edits far apart.

**Low output token calls:**

LLM calls with very few output tokens may indicate unnecessary deliberation — the model is making multiple round-trips where one would suffice:

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  LogAttributes['event.sequence'] AS seq,
  toUInt64OrZero(LogAttributes['output_tokens']) AS output_tokens,
  LogAttributes['model'] AS model
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_request'
  AND toUInt64OrZero(LogAttributes['output_tokens']) < 50
ORDER BY toUInt32OrZero(seq)
FORMAT PrettyCompact
```

Multiple consecutive low-output calls within the same `prompt.id` suggest the model is breaking work into too many steps.

**Bloated initial context:**

Check `cache_creation_tokens` on the first LLM call — this represents the full initial context (system prompt, CLAUDE.md, memory, skills, permissions):

```sql
SELECT
  LogAttributes['event.sequence'] AS seq,
  toUInt64OrZero(LogAttributes['cache_creation_tokens']) AS cache_creation,
  toUInt64OrZero(LogAttributes['input_tokens']) AS input_tokens,
  LogAttributes['model'] AS model
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_request'
ORDER BY toUInt32OrZero(seq)
LIMIT 3
FORMAT PrettyCompact
```

If `cache_creation_tokens` on the first call is above ~30k, the initial context may have room for optimization (large CLAUDE.md, many memory files, verbose skills). This feeds into Step 6 (Project Context Analysis) if project files are accessible.

**Subagent usage assessment:**

For each subagent spawn, evaluate whether it was justified by checking the Agent `tool_input` (for `description` and `subagent_type`) and the surrounding telemetry. These assessments are based on structural signals (tool counts, timing, token patterns) — not on the actual content flowing through the session. Present them as **likely** judgments with your reasoning, so the user can confirm or override based on their memory of what happened.

*Likely unnecessary — recommend inline approach:*
- Subagent `description` suggests a simple task (single file read, quick search) but the spawn + completion overhead added multiple LLM calls
- Only 1-2 tool calls happened between the Agent spawn and completion — the main agent could have done this directly
- Subagent was spawned for something the main agent already had context for (e.g., a file it just read or edited in a recent prompt)
- Single subagent spawned synchronously (not `run_in_background`) for a task that didn't need context isolation

*Likely justified — no change needed:*
- Multiple subagents ran in parallel (`run_in_background: true` in tool_input), reducing wall-clock time
- Subagent performed multi-step research (many LLM rounds and tool calls) that would have bloated the main context
- Subagent type was specialized (e.g., `Explore` for broad codebase search) and the task matched that specialization

*Could be improved:*
- Subagents spawned sequentially when they could have been parallel (look for Agent tool_decision/tool_result pairs with no time overlap)
- Completion prompts with high token counts — the main agent is spending too much processing subagent results; the subagent prompt could ask for more concise output
- Many subagents spawned for related tasks that could have been combined into fewer subagents with broader scope

**Missed subagent opportunities:**

When no subagents were used (or few were), look for telemetry patterns that suggest subagents *would have* reduced cost or wall-clock time. The core question is: did the main agent do work sequentially that could have been parallelized, or do research that bloated its context unnecessarily?

**Important:** these are heuristic recommendations based on structural patterns, not certainties. Telemetry shows *what* happened (tool calls, token counts, timing) but not *why*. Always present subagent recommendations as "likely opportunities" with your reasoning, and ask the user to confirm — they have the context you don't.

Use the per-prompt tool breakdown from Step 3 as a starting point. Run this additional query to add input token growth, which Step 3 doesn't capture:

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  countIf(LogAttributes['tool_name'] IN ('Grep', 'Glob', 'Read', 'Bash')) AS search_tool_calls,
  countIf(Body = 'claude_code.api_request') AS llm_calls,
  sum(toUInt64OrZero(LogAttributes['input_tokens'])) AS total_input_tokens,
  max(toUInt64OrZero(LogAttributes['input_tokens'])) - min(toUInt64OrZero(LogAttributes['input_tokens'])) AS input_token_growth
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body IN ('claude_code.tool_result', 'claude_code.api_request')
GROUP BY prompt_id
HAVING search_tool_calls >= 6 AND llm_calls >= 5
ORDER BY search_tool_calls DESC
FORMAT PrettyCompact
```

Prompts with many search tool calls and many LLM rounds are candidates — the agent was doing iterative exploration that an `Explore` subagent could have handled in isolation, keeping the main context lean.

Also check for input token growth across LLM calls within a prompt — a sign that search results are accumulating in context:

```sql
SELECT
  LogAttributes['prompt.id'] AS prompt_id,
  LogAttributes['event.sequence'] AS seq,
  toUInt64OrZero(LogAttributes['input_tokens']) AS input_tokens,
  toUInt64OrZero(LogAttributes['output_tokens']) AS output_tokens,
  LogAttributes['model'] AS model
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.api_request'
  AND LogAttributes['prompt.id'] = '<CANDIDATE_PROMPT_ID>'
ORDER BY toUInt32OrZero(seq)
FORMAT PrettyCompact
```

If input tokens grow significantly across consecutive LLM calls within one prompt (e.g., from 10k to 50k+), that's tool results accumulating in context — a subagent would have absorbed that growth instead of the main agent.

*Patterns that suggest missed subagent use:*

- **Sequential independent searches** — 6+ search tool calls (Grep, Glob, Read) across 5+ LLM rounds in a single prompt, especially when the `tool_input` JSON shows searches targeting different files or directories. An `Explore` subagent could have done this in parallel or in isolation, returning only the relevant findings.
- **Research-heavy prompts with context bloat** — input tokens growing by 3x+ across LLM calls within one prompt. The main agent is accumulating search results (large `tool_result_size_bytes` values) it only needs temporarily. A research subagent would keep this out of the main context window.
- **Multiple independent subtasks in one interaction** — look at `tool_input` JSON for tool calls targeting unrelated files or directories within the same prompt (e.g., editing `src/auth/` then searching `src/billing/`). These could have been split into parallel subagents.
- **Long-running Bash commands blocking progress** — Bash tool executions with `duration_ms` > 30000 where other work was pending. A background subagent could have run the slow command while the main agent continued.
- **Repeated similar searches** — multiple Grep/Glob calls where `tool_input` shows similar patterns but different paths or slight variations, suggesting the agent is casting a wide net. A single `Explore` subagent with a broader mandate would be more efficient.

*When subagents would NOT have helped (don't recommend them for these):*
- Short sessions (< 5 LLM calls total) — subagent overhead isn't worth it
- Tasks requiring tight sequential dependencies (each step depends on the previous result)
- Sessions where the agent already had strong context and just needed to apply it (few search calls, mostly edits)
- Single-file focused work — reading and editing the same file repeatedly doesn't benefit from parallelization

*Where these heuristics can mislead — present recommendations with this awareness:*

Telemetry can make subagents look beneficial when they wouldn't be:
- **Dependent search chains that look independent** — 8 sequential Grep calls looks like "parallelize this," but each search may have been informed by the previous result (found `handleAuth` → searched for `SessionManager` → found `TokenValidator`). Check `tool_input` for progressive narrowing — if search patterns evolve across calls (not just different paths for the same pattern), the searches were likely dependent and couldn't have been parallelized.
- **Context building that looks like bloat** — input tokens growing 3x across a prompt looks like waste, but the agent may have been reading related files to build understanding before a complex edit. If the prompt ends with a substantial Edit or Write (not more searches), the context growth was likely intentional.
- **Architecturally coupled paths** — `tool_input` showing work in `src/auth/` then `src/billing/` looks like independent subtasks, but the billing change may depend on understanding the auth contract. Path distance doesn't imply logical independence.

Telemetry can also hide cases where subagents would have helped:
- **Few LLM rounds but massive per-call token counts** — only 3 API calls looks efficient, but if each had 100k+ input tokens, the agent loaded everything into its own context. A subagent doing targeted research and returning a summary would have been far cheaper.
- **Small tool results hiding expensive re-reads** — `tool_result_size_bytes` looks modest per call, but the agent re-reads the same files across multiple prompts because it lost context. A subagent with focused scope could have kept that context alive.

When recommending subagent use, be specific about *which* pattern you saw, *what type* of subagent would help, and *what assumption* your recommendation rests on — so the user can confirm or correct it. For example: "Prompt 3 made 8 Grep calls across 6 LLM rounds searching for error handling patterns. The search patterns target different directories and don't appear to narrow progressively, suggesting they were independent. If so, an `Explore` subagent with `subagent_type: 'Explore'` could have done this in one shot and returned a summary, saving ~40k input tokens from accumulating in the main context. However, if each search depended on what the previous one found, the sequential approach was correct."

### Step 6: Project Context Analysis (conditional, feeds → Section 3, 4)

This step applies when the skill is run from within the project that was being worked on in the profiled session — meaning you have access to the project's files, not just telemetry. Skip this step if you don't have access to the target project directory.

The goal is to turn telemetry-only findings from Step 5 into project-specific recommendations. Each inspection below is **driven by a telemetry finding** — don't inspect everything; only look at what the data says matters.

**Detecting the project directory:**

Check `tool_input` from Read/Edit/Write/Glob/Grep tool calls in the session to identify the working directory:

```sql
SELECT
  LogAttributes['tool_name'] AS tool,
  JSONExtractString(LogAttributes['tool_input'], 'file_path') AS file_path
FROM otel_logs
WHERE ServiceName = 'claude-code'
  AND LogAttributes['session.id'] = '<SESSION_ID>'
  AND Body = 'claude_code.tool_result'
  AND LogAttributes['tool_name'] IN ('Read', 'Edit', 'Write', 'Glob', 'Grep')
LIMIT 20
FORMAT PrettyCompact
```

Extract the common root path — that's the project directory. If you can read files under that path, proceed. If not, note in the document that project-level recommendations would be more specific if the skill were run from within the target project.

**Inspect based on telemetry findings:**

*If high `cache_creation_tokens` on first LLM call (Step 1):*

The initial context is built from CLAUDE.md, memory files, permissions, and loaded skills. Inspect what's contributing:

- Read `<project>/CLAUDE.md` — count lines, identify sections that could be moved to reference files
- List `~/.claude/projects/<project-path>/memory/` — count files, read MEMORY.md index, check for stale or redundant entries
- Read `~/.claude/projects/<project-path>/settings.json` — check for verbose permission rules
- Check for large skill files being loaded (look at the session's loaded skills from telemetry)

Quantify what you find: "CLAUDE.md is 480 lines (~12k tokens). 14 memory files are indexed. Combined, these contribute an estimated ~25k tokens to the initial context. The telemetry shows 38k cache_creation_tokens on the first LLM call — so project config accounts for roughly 65% of the initial cache."

*If permission friction detected (Step 2/5):*

Read the project's permission settings and compare against the tools that were blocked:

- Read `~/.claude/projects/<project-path>/settings.json` and `~/.claude/settings.json`
- For each tool with high blocked counts, check if there's an existing allow rule that's too narrow or missing entirely
- Draft the exact permission rule to add, e.g.: `{"tool": "Bash", "command": "curl -s*"}` for frequently-approved curl commands

*If repeated file reads across prompts (context loss):*

Check whether the files being re-read could be summarized in CLAUDE.md or a reference file:

- Identify the most re-read files from `tool_input` across prompts
- Read those files — are they stable reference material (architecture docs, API schemas) or frequently changing code?
- If stable: recommend adding a summary to CLAUDE.md or a skill reference file
- If changing: this is expected behavior, not a problem

*If subagent-related findings (Step 4/5):*

Check whether the project's CLAUDE.md or skills give guidance on when to use subagents:

- Does CLAUDE.md mention subagent preferences or restrictions?
- Are there skills that overlap with what subagents were doing (e.g., an Explore-type skill that could replace ad-hoc Explore subagents)?
- If subagents were under/over-used, recommend adding a brief note to CLAUDE.md about preferred subagent strategy for this project

*If high tool execution times (Step 2):*

For slow Bash commands, check the project for context:

- Are there faster alternatives in the project's toolchain? (e.g., a Makefile target, a project-specific script)
- Is the slow command hitting a known issue? (check CLAUDE.md for notes about build times, test suites, etc.)

**Adding project context to the document:**

Don't create a separate section for project findings. Instead, enrich the existing findings in Section 3 and recommendations in Section 4 with the project-specific details. For example, a finding about "high initial context" should show both the telemetry evidence (cache_creation_tokens = 38k) and the project evidence (CLAUDE.md = 480 lines, 14 memory files). The recommendation should include the specific changes: "Remove the ClickHouse query reference section (lines 45-120) from CLAUDE.md and move it to `references/clickhouse-queries.md` — estimated savings: ~4k tokens per session."

When project files aren't accessible, note this at the end of the document: "This analysis is based on telemetry data only. Running the profiler from within the target project (`<detected path>`) would enable project-specific recommendations for CLAUDE.md optimization, permission tuning, and memory file management."

## Output: Session Analysis Document

Save the analysis to `<working-directory>/session-reports/session-<SESSION_ID_SHORT>.md` (first 8 chars of session ID). Create `session-reports/` if needed.

**Before writing the document**, read `${CLAUDE_PLUGIN_ROOT}/skills/claude-session-profiler/references/document-template.md` for the full document structure, mermaid diagram construction rules, and section templates. The template includes the diagram query, event-to-mermaid mapping, and the finding/recommendation format.

**Key principles:**
- Every recommendation must point back to a numbered finding with specific telemetry evidence
- State confidence levels and assumptions explicitly — the user needs to see your reasoning to validate or correct it
- After saving, give the user a brief verbal summary (3-5 sentences) and the file path
- If you can't point to data that supports a recommendation, don't make it
- In findings, note whether evidence came from logs or traces — this helps the user understand what telemetry level was needed for each insight

**Mermaid diagram:** Follow the event-to-diagram mapping in `${CLAUDE_PLUGIN_ROOT}/skills/claude-session-profiler/references/document-template.md` strictly. The diagram should be built from actual telemetry events (query results from the diagram query in the template), not from a narrative summary. Each event maps to a specific arrow type — `user_prompt` → `User ->> Claude`, `tool_decision`/`tool_result` → `Claude ->> Tools`, `api_request` → `Claude ->> Claude: LLM call`, etc. Use the collapsing rules for repetitive sequences (3+ consecutive same-tool calls become one line with a count).
