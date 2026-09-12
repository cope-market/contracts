#!/usr/bin/env bash
#
# Feeds prices to PushOracle on Arc.
#
# This exists only because Pyth's pull path does not work on Arc testnet (see SPIKE.md). With Pyth,
# each trade carries its own price update and nothing needs to run. PushOracle stores whatever was
# last written to it, so without this job the vault has no prices and no trade can open or close.
#
# Delete this when Arc fixes its Pyth deployment and ORACLE_KIND becomes `pyth`.
#
# Usage
#   ./script/price-pusher.sh --once
#   ./script/price-pusher.sh --interval 60
#
# Required env
#   PYTH_API_KEY   Hermes key. Only feeds the key is entitled to can be fetched.
#   RPC_URL        Arc RPC endpoint.
#   ORACLE         PushOracle address.
#   PRIVATE_KEY    Pusher key.  (or CAST_ACCOUNT for a keystore entry)
#
# Options
#   --once              One cycle, then exit. Default.
#   --interval SECONDS  Loop forever. Must stay well under the vault's maxAgeSec.
#   --stamp-now         Publish under the current chain time rather than Hermes' publish time.
#                       Markets close; Hermes then returns the same publish time for hours or days
#                       and every push is correctly rejected as not-newer. This flag keeps a demo
#                       tradeable out of hours by asserting a freshness the data does not have.
#                       Acceptable only against an oracle already documented as fully trusted.
set -euo pipefail

INTERVAL=0
STAMP_NOW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) INTERVAL=0; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --stamp-now) STAMP_NOW=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

: "${PYTH_API_KEY:?set PYTH_API_KEY}"
: "${RPC_URL:?set RPC_URL}"
: "${ORACLE:?set ORACLE}"

if [[ -n "${PRIVATE_KEY:-}" ]]; then
  SIGNER=(--private-key "$PRIVATE_KEY")
elif [[ -n "${CAST_ACCOUNT:-}" ]]; then
  SIGNER=(--account "$CAST_ACCOUNT")
else
  echo "set PRIVATE_KEY or CAST_ACCOUNT" >&2; exit 2
fi

# Only feeds the Hermes key is entitled to. AAPL, SPY and NVDA return 403 and one unentitled feed
# fails the whole request, so they cannot simply be added to this list. See SPIKE.md.
declare -A FEEDS=(
  [FX.EUR/USD]=a995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b
  [Metal.XAU/USD]=765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2
  [Crypto.BTC/USD]=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
  [Equity.US.TSLA/USD]=16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1
)

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

cycle() {
  local query="" id
  for id in "${FEEDS[@]}"; do query+="ids%5B%5D=${id}&"; done

  local body
  if ! body=$(curl -sfL --max-time 30 -H "Authorization: Bearer ${PYTH_API_KEY}" \
       "https://hermes.pyth.network/v2/updates/price/latest?${query}parsed=true&encoding=hex"); then
    log "hermes fetch failed; skipping cycle"
    return 0
  fi

  local chain_now
  chain_now=$(cast block latest --rpc-url "$RPC_URL" --field timestamp | awk '{print $1}')

  # Read what the oracle already holds so feeds with no newer data are dropped. PushOracle requires
  # strictly increasing publish times, so including an unchanged one would revert the whole batch.
  local stored=""
  for id in "${FEEDS[@]}"; do
    # awk strips cast's "1789210086 [1.789e9]" annotation, which only appears on large values -
    # the first run passed because every stored timestamp was still 0.
    stored+="0x${id}:$(cast call "$ORACLE" 'lastPublishTime(bytes32)(uint64)' "0x${id}" --rpc-url "$RPC_URL" | awk '{print $1}') "
  done

  local plan
  plan=$(STORED="$stored" CHAIN_NOW="$chain_now" STAMP_NOW="$STAMP_NOW" python3 -c '
import json, os, sys

data = json.loads(sys.stdin.read())
stored = dict(
    (k.lower(), int(v))
    for k, v in (p.split(":") for p in os.environ["STORED"].split())
)
chain_now = int(os.environ["CHAIN_NOW"])
stamp_now = os.environ["STAMP_NOW"] == "1"

ids, prices, confs, times, skipped = [], [], [], [], []
for entry in data.get("parsed", []):
    feed = "0x" + entry["id"].lower()
    p = entry["price"]
    expo = int(p["expo"])
    shift = 18 + expo
    scale = (lambda v: v * 10 ** shift if shift >= 0 else v // 10 ** -shift)

    price = scale(int(p["price"]))
    conf = scale(int(p["conf"]))
    published = int(p["publish_time"])

    if price <= 0:
        skipped.append((feed, "non-positive price"))
        continue

    stamp = chain_now if stamp_now else published
    if stamp > chain_now:
        stamp = chain_now          # never publish under a future timestamp
    if stamp <= stored.get(feed, 0):
        skipped.append((feed, "no newer data (market closed?)"))
        continue

    ids.append(feed); prices.append(price); confs.append(conf); times.append(stamp)

print(json.dumps({
    "ids": ids, "prices": prices, "confs": confs, "times": times,
    "skipped": skipped, "count": len(ids),
}))
' <<<"$body")

  local count
  count=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' <<<"$plan")

  python3 -c '
import json, sys
d = json.load(sys.stdin)
for feed, why in d["skipped"]:
    print("  skip", feed[:12] + "...", why)
' <<<"$plan"

  if [[ "$count" -eq 0 ]]; then
    log "nothing to push"
    return 0
  fi

  local a b c e
  a=$(python3 -c 'import json,sys; print("["+",".join(json.load(sys.stdin)["ids"])+"]")' <<<"$plan")
  b=$(python3 -c 'import json,sys; print("["+",".join(map(str,json.load(sys.stdin)["prices"]))+"]")' <<<"$plan")
  c=$(python3 -c 'import json,sys; print("["+",".join(map(str,json.load(sys.stdin)["confs"]))+"]")' <<<"$plan")
  e=$(python3 -c 'import json,sys; print("["+",".join(map(str,json.load(sys.stdin)["times"]))+"]")' <<<"$plan")

  if cast send "$ORACLE" \
      'pushMany(bytes32[],uint256[],uint256[],uint64[])' "$a" "$b" "$c" "$e" \
      --rpc-url "$RPC_URL" "${SIGNER[@]}" >/dev/null; then
    log "pushed $count feed(s)"
  else
    log "push failed; will retry next cycle"
  fi
}

[[ "$STAMP_NOW" -eq 1 ]] && log "WARNING --stamp-now: publishing under chain time, not real market time"

if [[ "$INTERVAL" -eq 0 ]]; then
  cycle
else
  log "pushing every ${INTERVAL}s (keep well under the vault's maxAgeSec)"
  while true; do cycle || log "cycle errored; continuing"; sleep "$INTERVAL"; done
fi
