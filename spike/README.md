# Spike: streaming WS-bridged guardrail (`spike-stream-bridge`)

THROWAWAY spike for the go/no-go question in
[`docs/design/ai-cato-networks-guard-streaming-spike.md`](../docs/design/ai-cato-networks-guard-streaming-spike.md):

> Can a Kong plugin take over the request in the `access` phase and stream a
> WebSocket-bridged response to the client — withholding chunks until a Cato
> Networks verdict clears (and optionally modifies) them?

This is **not** production code. It is staged so each risk is validated in
isolation. The single highest-risk question — incremental `ngx.print`/`ngx.flush`
output from the `access` phase (`stage = static`) — is the gate: if it fails, the
in-Kong design is dead and the guardrail must be a sidecar.

## Layout

```
spike/
  kong/plugins/spike-stream-bridge/   handler.lua, schema.lua  (the staged plugin)
  mocks/nginx.conf                    SSE upstream (:9000) + Cato Networks WS (:9001)
  run/kong.yml                        DB-less config, one route per stage
  run/kong.conf                       DB-less Kong config
  run/test.sh                         curl -N driver + hold-back safety assertion
  NOTES.md                            findings + go/no-go (fill in after running)
```

## Run (in a Kong / OpenResty dev environment)

```bash
# 1. mocks
cd spike/mocks && mkdir -p logs && openresty -p "$PWD" -c nginx.conf

# 2. Kong DB-less with the spike plugin on the package path
cd ../run
KONG_LUA_PACKAGE_PATH="$(cd .. && pwd)/?.lua;;" kong start -c kong.conf

# 3. drive it
./test.sh
```

## Stages → plan steps

| Route | stage | Validates |
|---|---|---|
| `/spike/static` | `static` | **GATE** — incremental output from `access` |
| `/spike/upstream` | `upstream` | streamed upstream read |
| `/spike/ws` | `ws` | outbound WS round-trip from `access` |
| `/spike/bridge` | `bridge` | duplex hold-back bridge + chunk modification |
| `/spike/bridge-block` | `bridge` | block scenario — withheld chunk must never leak |

Record results and the go/no-go call in `NOTES.md`.
