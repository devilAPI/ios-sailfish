#!/bin/bash
# oc.sh DIR "TASK" [LOG]: one small task for the local model as an opencode
# agent (default model in ~/.config/opencode/opencode.json:
# ollama/qwen3.5-9b-iq4xs-24k) working in DIR with its own file tools.
# stdin must not be a terminal or a pipe it waits on (< /dev/null), or
# opencode waits for input. Default limit 20 min. Review its changes
# (git diff in DIR) before committing anything.
set -u
dir=$1 task=$2 log=${3:-/dev/stdout}
cd "$dir" || exit 1
timeout "${OC_TIMEOUT:-1200}" opencode run "$task" < /dev/null > "$log" 2>&1
echo "opencode exit $?" >> "$log"
