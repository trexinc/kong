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
  run/docker-compose.yml              Kong + mocks, fully containerized  (PRIMARY)
  run/kong.docker.yml                 DB-less config for compose (service-name hosts)
  run/kong.yml                        DB-less config for a local Kong binary (127.0.0.1)
  run/kong.conf                       DB-less Kong config for a local Kong binary
  run/test.sh                         curl -N driver + hold-back safety assertion
  NOTES.md                            findings + go/no-go (fill in after running)
```

## Run — Docker (recommended; needs only Docker Desktop)

The OSS Kong Homebrew formula was dropped, so run everything in containers.
Both the mocks (OpenResty image) and Kong (official image) come up via Compose;
nothing is installed on the host.

```bash
cd spike/run
docker compose up                 # Ctrl-C to stop; `docker compose down` to clean up

# in another terminal:
./test.sh                         # drives http://127.0.0.1:8000

# iterate:
docker compose restart kong       # after editing handler.lua / schema.lua
docker compose restart mocks      # after editing mocks/nginx.conf
```

Plugin logs appear on the `kong` container's stdout (`docker compose logs -f kong`).
Mock WS logs: `docker compose logs -f mocks`.

## Run — local Kong binary (alternative, if you have one)

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
