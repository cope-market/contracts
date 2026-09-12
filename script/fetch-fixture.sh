#!/usr/bin/env bash
# Refreshes the Pyth update blob used by test/PythArcFork.t.sol.
# Usage: PYTH_API_KEY=... ./script/fetch-fixture.sh
set -euo pipefail
EUR=a995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b
OUT="$(dirname "$0")/../test/fixtures"
mkdir -p "$OUT"
curl -sfL --max-time 30 -H "Authorization: Bearer ${PYTH_API_KEY}" \
  "https://hermes.pyth.network/v2/updates/price/latest?ids%5B%5D=${EUR}&encoding=hex" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
open('${OUT}/pyth_eurusd.hex','w').write('0x'+d['binary']['data'][0])
p=d['parsed'][0]['price']
open('${OUT}/pyth_eurusd.json','w').write(json.dumps({
  'publishTime':p['publish_time'],'price':p['price'],'expo':p['expo'],'conf':p['conf']}))
print('publishTime',p['publish_time'],'price',p['price'],'expo',p['expo'])
"
