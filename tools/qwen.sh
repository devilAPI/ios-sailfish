#!/bin/bash
# qwen.sh "TASK" [FILE...]: one small text task for the local model (Ollama,
# qwen3.5-9b-iq4xs-24k on the developer PC). Files are appended to the prompt
# as fenced blocks. The model has a 24k-token context: input is capped at
# QWEN_MAX_CHARS (default 60000 characters, about 15k tokens) so the answer
# still fits. Output: the model's answer on stdout. Use it for reviews of
# small diffs, condensing pre-filtered logs, drafting short texts; check what
# it says, it is a 9B model.
set -euo pipefail
task=$1; shift
max=${QWEN_MAX_CHARS:-60000}
model=${QWEN_MODEL:-qwen3.5-9b-iq4xs-24k}
python3 -I - "$task" "$max" "$model" "$@" <<'EOF'
import json, sys, urllib.request
task, maxc, model, files = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
parts = [task]
for f in files:
    parts.append(f"\n--- {f} ---\n```\n{open(f, errors='replace').read()}\n```")
prompt = "\n".join(parts)
if len(prompt) > maxc:
    prompt = prompt[:maxc] + "\n[... input cut at %d characters ...]" % maxc
req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps({
    "model": model, "stream": False, "think": False,
    "options": {"temperature": 0.2},
    "messages": [{"role": "system", "content": "You are a careful embedded Linux and Android engineer. Answer briefly and concretely. Say when you are unsure."},
                 {"role": "user", "content": prompt}]}).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=900) as r:
    print(json.load(r)["message"]["content"].strip())
EOF
