# iothub/e2e

The lifecycle script starts the real gateway, checks authentication and rate
limiting, registers devices, configures an alert, ingests telemetry, queries
the time series, restarts for recovery, verifies the audit chain, and prints
metrics. It is intentionally driven through the TCP MemoryPack protocol.
