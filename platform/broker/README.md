# platform/broker

Internal durable pub/sub broker. It provides CRC-framed MemoryPack events,
topic-local offsets, committed consumer groups, and at-least-once fetch/commit
semantics for asynchronous alert processing.
