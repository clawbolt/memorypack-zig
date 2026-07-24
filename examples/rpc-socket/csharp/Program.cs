using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using MemoryPack;

if (args.Length != 1 || !ushort.TryParse(args[0], out var port))
    throw new ArgumentException("usage: <port>");

using var listener = new TcpListener(IPAddress.Loopback, port);
listener.Start();
Console.WriteLine($"RPC server listening on 127.0.0.1:{port}");
Console.Out.Flush();

using var client = await listener.AcceptTcpClientAsync();
await using var stream = client.GetStream();
Console.WriteLine("RPC server accepted Zig client");
Console.Out.Flush();

while (true)
{
    var request = await ReadMessage<Request>(stream);
    Console.WriteLine($"request id={request.Id} command={request.Command}");

    var response = Handle(request);
    await WriteMessage(stream, response);
    Console.WriteLine($"response id={response.Id} ok={response.Ok} message={response.Message}");
    Console.Out.Flush();

    if (request.Command == "shutdown")
        break;
}

static Response Handle(Request request)
{
    return request.Command switch
    {
        "ping" => new Response { Id = request.Id, Ok = true, Message = "pong" },
        "echo" => new Response
        {
            Id = request.Id,
            Ok = true,
            Message = string.Join(' ', request.Args),
        },
        "add" => Add(request),
        "shutdown" => new Response { Id = request.Id, Ok = true, Message = "bye" },
        _ => new Response { Id = request.Id, Ok = false, Message = "unknown command" },
    };
}

static Response Add(Request request)
{
    if (request.Args.Any(arg => !int.TryParse(arg, out _)))
        return new Response { Id = request.Id, Ok = false, Message = "invalid number" };

    var sum = request.Args.Sum(int.Parse);
    return new Response { Id = request.Id, Ok = true, Message = sum.ToString() };
}

static async Task<T> ReadMessage<T>(NetworkStream stream)
{
    var lengthBytes = new byte[4];
    await ReadExactly(stream, lengthBytes);
    var length = BinaryPrimitives.ReadInt32LittleEndian(lengthBytes);
    if (length < 0 || length > 1024 * 1024)
        throw new InvalidDataException("invalid message length");

    var payload = new byte[length];
    await ReadExactly(stream, payload);
    return MemoryPackSerializer.Deserialize<T>(payload)
        ?? throw new InvalidDataException("null MemoryPack message");
}

static async Task WriteMessage<T>(NetworkStream stream, T value)
{
    var payload = MemoryPackSerializer.Serialize(value);
    var lengthBytes = new byte[4];
    BinaryPrimitives.WriteInt32LittleEndian(lengthBytes, payload.Length);
    await stream.WriteAsync(lengthBytes);
    await stream.WriteAsync(payload);
    await stream.FlushAsync();
}

static async Task ReadExactly(NetworkStream stream, byte[] buffer)
{
    var offset = 0;
    while (offset < buffer.Length)
    {
        var read = await stream.ReadAsync(buffer.AsMemory(offset));
        if (read == 0)
            throw new EndOfStreamException();
        offset += read;
    }
}

[MemoryPackable]
public partial class Request
{
    public int Id { get; set; }
    public string Command { get; set; } = "";
    public string[] Args { get; set; } = Array.Empty<string>();
}

[MemoryPackable]
public partial class Response
{
    public int Id { get; set; }
    public bool Ok { get; set; }
    public string Message { get; set; } = "";
}
