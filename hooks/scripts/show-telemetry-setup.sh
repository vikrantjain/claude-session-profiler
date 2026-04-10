#!/bin/bash
# Check telemetry env vars and report missing ones to Claude (minimal context)

missing=()

check_var() {
  [ -z "${!1}" ] && missing+=("$1")
}

check_var "CLAUDE_CODE_ENABLE_TELEMETRY"
check_var "OTEL_LOG_TOOL_DETAILS"
check_var "OTEL_LOG_USER_PROMPTS"
check_var "OTEL_LOG_TOOL_CONTENT"
check_var "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"
check_var "OTEL_METRICS_EXPORTER"
check_var "OTEL_LOGS_EXPORTER"
check_var "OTEL_TRACES_EXPORTER"
check_var "OTEL_EXPORTER_OTLP_PROTOCOL"
check_var "OTEL_EXPORTER_OTLP_ENDPOINT"
check_var "OTEL_RESOURCE_ATTRIBUTES"

if [ ${#missing[@]} -eq 0 ]; then
  echo "Session profiler: all telemetry vars set in current env."
else
  echo "Session profiler: missing telemetry vars in current env: ${missing[*]}. Inform user what these affect and that they must be set before starting the session to monitor. Docs: https://code.claude.com/docs/en/monitoring-usage"
fi
