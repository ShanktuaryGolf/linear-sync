#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then set -a; source .env; set +a; fi
source .venv/bin/activate
python bot.py
