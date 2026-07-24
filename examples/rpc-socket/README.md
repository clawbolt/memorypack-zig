# MemoryPack RPC over TCP: Zig ↔ C#

This example demonstrates live cross-language communication rather than
file-based exchange:

1. A real C# MemoryPack 1.21.3 server listens on localhost.
2. A Zig client connects over TCP.
3. Every request and response is serialized with MemoryPack on its respective
   side.
4. The client verifies replies for `ping`, `echo`, `add`, and an unknown
   command, then sends `shutdown`.

## Framing

MemoryPack payloads are not self-delimiting when placed on a byte stream. The
example therefore wraps every payload in this transport frame:

```text
4-byte little-endian unsigned payload length
MemoryPack payload bytes
```

Both implementations loop until all four length bytes and all payload bytes
have been read. The frame length is capped at 1 MiB.

## Schema

The C# and Zig declarations have the same member order and widths:

```text
Request
  id: int32
  command: string / memorypack.Str
  args: string[] / []const memorypack.Str

Response
  id: int32
  ok: bool
  message: string / memorypack.Str
```

The wire payload uses only objects, strings, arrays, integers, and booleans.
No unordered collections are involved.

## Run

From the repository root:

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/rpc-socket/run.sh
```

The default port is `39123`. Override it with the first argument:

```sh
./examples/rpc-socket/run.sh 39200
```

The Zig client can also be run directly when a compatible C# server is already
listening:

```sh
zig build rpc-client -- 39123
```

## Commands

| Command | Arguments | Response |
| --- | --- | --- |
| `ping` | none | `pong` |
| `echo` | `hello world` | `hello world` |
| `add` | `7 35` | `42` |
| `unknown` | none | `ok=false`, `unknown command` |
| `shutdown` | none | `bye`, then the server exits |

## Example output

```text
=== Starting real C# MemoryPack RPC server on port 39123 ===

=== Zig client exchange ===
=== Zig RPC client connected to 127.0.0.1:39123 ===
request id=1 command=ping
  response id=1, ok=true, message=pong
request id=2 command=echo args=[hello, world]
  response id=2, ok=true, message=hello world
request id=3 command=add args=[7, 35]
  response id=3, ok=true, message=42
request id=4 command=unknown
  response id=4, ok=false, message=unknown command
request id=5 command=shutdown
  response id=5, ok=true, message=bye
RPC assertions: passed

=== C# server log ===
RPC server listening on 127.0.0.1:39123
RPC server accepted Zig client
request id=1 command=ping
response id=1 ok=True message=pong
request id=2 command=echo
response id=2 ok=True message=hello world
request id=3 command=add
response id=3 ok=True message=42
request id=4 command=unknown
response id=4 ok=False message=unknown command
request id=5 command=shutdown
response id=5 ok=True message=bye
```
