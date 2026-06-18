# Spike findings — `spike-stream-bridge`

Fill this in while running the spike in a Kong/OpenResty dev environment.
This drives the go/no-go decision for the full `ai-cato-networks-guard` plugin.

Kong version: ______   OpenResty version: ______   Date: ______

## Results

| Step | Stage / route | Expected | Observed | Pass? |
|---|---|---|---|---|
| 1 (GATE) | static `/spike/static` | 5 lines ~300ms apart, not one blob | | |
| — | log phase ran after takeover? | `spike: log phase ran...` in Kong log | | |
| 2 | upstream `/spike/upstream` | tok1..tok8 incremental (~250ms) | | |
| 3 | ws `/spike/ws` | 4 ws-echo lines | | |
| 4 | bridge `/spike/bridge` | lookahead delay; even chunks UPPERCASED | | |
| 5 | bridge-block `/spike/bridge-block` | block event; `tok3` never delivered | | |

## Failure / lifecycle observations (step 5 detail)

- Client disconnect mid-stream (`curl` killed): did both threads tear down?
  (look for orphaned upstream/WS connections; `ngx.print` error propagation) ___
- WS connect failure with `fail_open=true` vs `false`: ___
- Upstream timeout / WS timeout teardown: ___

## Latency

- Per-chunk overhead added by the WS round-trip (step 3/4): ______ ms

## Open questions surfaced

- SSE re-framing: `body_reader` chunk boundaries vs SSE event boundaries — does
  the real plugin need to buffer to event boundaries before sending to Cato? ___
- `ngx.exit(ngx.HTTP_OK)` from `access` vs Kong's wrapper finalization: any
  warnings/errors in Kong logs? ___
- Anything else: ___

## Decision

- [ ] **GO** — steps 1–4 pass, step 5 teardown clean + hold-back safety holds.
      Proceed to the full `ai-cato-networks-guard` plan.
- [ ] **NO-GO (sidecar)** — step 1 failed or duplex teardown unreliable.
      Re-open the sidecar-vs-in-Kong decision with stakeholders.

Notes: ___
