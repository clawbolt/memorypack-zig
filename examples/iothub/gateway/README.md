# examples/iothub/gateway

Authenticated front door for iothub. It routes MemoryPack requests to
domain services, checks per-request tokens, applies per-token rate limits, and
returns typed response objects with metrics-friendly status.
