#!/bin/bash
# Send a test notification to verify hookline is wired up correctly

CONFIG_FILE="${HOME}/.config/hookline/config"
source "$CONFIG_FILE" 2>/dev/null || { echo "Config not found. Run install.sh first."; exit 1; }

TOPIC="${HOOKLINE_TOPIC:?HOOKLINE_TOPIC not set}"
SERVER="${HOOKLINE_NTFY_SERVER:-https://ntfy.sh}"
RESPONSE_TOPIC="${TOPIC}-response"
REQ_ID="test-$(date +%s)"

echo "Sending test notification to topic: $TOPIC"
echo "Tap Allow or Deny on your phone..."

curl -s -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --arg topic "$TOPIC" \
    --arg url "${SERVER}/${RESPONSE_TOPIC}" \
    '{
      topic: $topic,
      title: "[hookline] Test Notification",
      message: "hookline is working! Tap Allow to confirm.",
      priority: 4,
      tags: ["white_check_mark"],
      actions: [
        {action:"http", label:"Allow", url:$url, method:"POST", body:("allow|" + "'$REQ_ID'")},
        {action:"http", label:"Deny",  url:$url, method:"POST", body:("deny|"  + "'$REQ_ID'")}
      ]
    }')" "${SERVER}/" | jq -r '.id // "failed"'

echo "Waiting for response (30s)..."
elapsed=0
since_id=""
while [ "$elapsed" -lt 30 ]; do
  sleep 3
  elapsed=$((elapsed + 3))
  msgs=$(curl -s --max-time 5 "${SERVER}/${RESPONSE_TOPIC}/json?poll=1${since_id:+&since=$since_id}")
  while IFS= read -r msg; do
    [ -z "$msg" ] && continue
    msg_id=$(echo "$msg" | jq -r '.id // empty')
    MSG=$(echo "$msg" | jq -r '.message // empty')
    [ -n "$msg_id" ] && since_id="$msg_id"
    if [[ "$MSG" == *"|$REQ_ID" ]]; then
      decision="${MSG%%|*}"
      echo "Response received: $decision"
      exit 0
    fi
  done <<< "$msgs"
done

echo "No response received within 30s."
exit 1
