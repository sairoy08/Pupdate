#!/bin/bash
# Keeps the Pupdate backend and its permanent public link alive for the demo.
# - Prevents the Mac from sleeping (keep it plugged in; the lid can stay open on a table).
# - Restarts the backend or ngrok if either one exits.
# Usage: ./demo-server.sh            (Ctrl-C to stop everything)
DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${PUPDATE_URL:-${WALKBUDDY_URL:-zesty-decompose-tinwork.ngrok-free.dev}}"
LOGS="$DIR/.logs"; mkdir -p "$LOGS"

caffeinate -dimsu -w $$ &

keep() {  # keep <name> <command...>: rerun the command whenever it exits
  local name=$1; shift
  while true; do
    echo "$(date '+%H:%M:%S') starting $name" >> "$LOGS/supervisor.log"
    "$@" >> "$LOGS/$name.log" 2>&1
    echo "$(date '+%H:%M:%S') $name exited ($?), restarting in 2s" >> "$LOGS/supervisor.log"
    sleep 2
  done
}

cd "$DIR/backend"
pkill -f "uvicorn app.main:app --host 0.0.0.0 --port 8100" 2>/dev/null
pkill -f "ngrok http" 2>/dev/null
sleep 1
keep backend .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8100 &
keep tunnel ngrok http 8100 --url="$URL" --log stdout &
echo "Pupdate is live at https://$URL  (logs in $LOGS). Ctrl-C to stop."
trap 'pkill -P $$; pkill -f "ngrok http"; pkill -f "port 8100"; exit 0' INT TERM
wait
