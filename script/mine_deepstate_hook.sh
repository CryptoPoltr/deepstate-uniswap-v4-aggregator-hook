#!/usr/bin/env bash
set -euo pipefail

# Mines a DeepStateAggregator CREATE2 salt in consecutive windows.
# Required environment variables:
#   PLANNER
#   ROUTING_FEE_RECIPIENT
#   RPC_URL            (target chain; used to check that the mined address has no code)
# Optional:
#   INITIAL_SALT_OFFSET (defaults to 0)
#   MAX_ATTEMPTS      (defaults to 500 windows)

: "${PLANNER:?PLANNER is required}"
: "${ROUTING_FEE_RECIPIENT:?ROUTING_FEE_RECIPIENT is required}"
: "${RPC_URL:?RPC_URL is required}"

SALT_INCREMENT=160444
INITIAL_SALT_OFFSET=${INITIAL_SALT_OFFSET:-0}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-500}

for ((i = 0; i < MAX_ATTEMPTS; ++i)); do
    OFFSET=$((INITIAL_SALT_OFFSET + i * SALT_INCREMENT))
    echo "Mining attempt $((i + 1))/$MAX_ATTEMPTS (salt offset: $OFFSET)"

    set +e
    OUTPUT=$(SALT_OFFSET="$OFFSET" FOUNDRY_PROFILE=aggregator_hooks \
        forge script script/MineDeepStateAggregator.s.sol:MineDeepStateAggregator --rpc-url "$RPC_URL" 2>&1)
    STATUS=$?
    set -e

    if [[ $STATUS -eq 0 ]] && grep -q "DeepState Aggregator Hook Mining Result" <<<"$OUTPUT"; then
        echo "$OUTPUT"
        exit 0
    fi

    if grep -qE "SaltNotFound|could not find salt" <<<"$OUTPUT"; then
        continue
    fi

    echo "$OUTPUT" >&2
    if [[ $STATUS -eq 0 ]]; then
        echo "Mining command exited successfully but produced no recognized result." >&2
        exit 1
    fi
    exit "$STATUS"
done

echo "No matching salt found after $MAX_ATTEMPTS windows." >&2
exit 1
