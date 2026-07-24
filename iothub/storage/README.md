# iothub/storage

Generic durable MemoryPack key/value storage with snapshot, CRC-protected WAL,
replay, compaction, and mutex-protected CRUD. IotHub services use namespaced
keys to model device, reading, rule, and alert collections.
