using System.Text;
using System.Runtime.InteropServices;
using MemoryPack;

Directory.CreateDirectory("interop/vectors");

if (args.Length == 0)
{
    Console.WriteLine($"MemoryPack interop harness, .NET {Environment.Version}");
    return;
}

if (args[0] == "generate")
{
    Harness.GenerateVectors();
    Console.WriteLine("C# -> Zig vectors generated");
}
else if (args[0] == "verify-zig")
{
    Harness.VerifyZigVectors();
    Console.WriteLine("Zig -> C# vectors verified");
}
else
{
    throw new ArgumentException($"Unknown mode: {args[0]}");
}

[MemoryPackable]
public partial class BasicObject
{
    public int Id { get; set; }
    public string? Name { get; set; }
}

[MemoryPackable]
public partial class NestedObject
{
    public BasicObject? Inner { get; set; }
    public int[]? Values { get; set; }
}

public enum Level : byte
{
    Novice = 2,
    Expert = 7,
}

[MemoryPackable]
public partial class RichObject
{
    public ulong Id { get; set; }
    public string? Name { get; set; }
    public byte[]? Data { get; set; }
    public Level Level { get; set; }
    public BasicObject? Child { get; set; }
}

[StructLayout(LayoutKind.Sequential)]
public struct Padded
{
    public byte A;
    public int B;
}

public static class Harness
{
const string VectorDir = "interop/vectors";

public static void GenerateVectors()
{
    Write("object.bin", new BasicObject { Id = 42, Name = "Ada" });
    Write("object_null_string.bin", new BasicObject { Id = -5, Name = null });
    Write("nested.bin", new NestedObject
    {
        Inner = new BasicObject { Id = 9, Name = "inner" },
        Values = new[] { 1, 2, 3 },
    });
    Write("nested_null_collection.bin", new NestedObject
    {
        Inner = null,
        Values = null,
    });
    Write("padded.bin", new Padded { A = 0x7f, B = 0x12345678 });
    Write("array_empty.bin", Array.Empty<int>());
    Write("array_null.bin", (int[]?)null);
    Write("string_empty.bin", string.Empty);
    Write("string_unicode.bin", "héllo 🌍");
    Write("string_null.bin", (string?)null);
    Write("bytes.bin", new byte[] { 0, 1, 2, 255 });
    Write("enum.bin", Level.Expert);
    Write("nullable_value.bin", (int?)1234);
    Write("nullable_value_null.bin", (int?)null);
    Write("nullable_object.bin", (BasicObject?)null);
    Write("rich.bin", new RichObject
    {
        Id = 99,
        Name = "Zig",
        Data = new byte[] { 8, 9, 10 },
        Level = Level.Expert,
        Child = new BasicObject { Id = 11, Name = "child" },
    });
}

public static void VerifyZigVectors()
{
    Verify("object.bin", new BasicObject { Id = 42, Name = "Ada" });
    Verify("object_null_string.bin", new BasicObject { Id = -5, Name = null });
    Verify("nested.bin", new NestedObject
    {
        Inner = new BasicObject { Id = 9, Name = "inner" },
        Values = new[] { 1, 2, 3 },
    });
    Verify("nested_null_collection.bin", new NestedObject { Inner = null, Values = null });
    Verify("padded.bin", new Padded { A = 0x7f, B = 0x12345678 });
    Verify("array_empty.bin", Array.Empty<int>());
    Verify("array_null.bin", (int[]?)null);
    Verify("string_empty.bin", string.Empty);
    Verify("string_unicode.bin", "héllo 🌍");
    Verify("string_null.bin", (string?)null);
    Verify("bytes.bin", new byte[] { 0, 1, 2, 255 });
    Verify("enum.bin", Level.Expert);
    Verify("nullable_value.bin", (int?)1234);
    Verify("nullable_value_null.bin", (int?)null);
    Verify("nullable_object.bin", (BasicObject?)null);
    Verify("rich.bin", new RichObject
    {
        Id = 99,
        Name = "Zig",
        Data = new byte[] { 8, 9, 10 },
        Level = Level.Expert,
        Child = new BasicObject { Id = 11, Name = "child" },
    });
}

static void Write<T>(string name, T value)
{
    File.WriteAllBytes(Path.Combine(VectorDir, name), MemoryPackSerializer.Serialize(value));
}

static void Verify<T>(string name, T expected)
{
    var path = Path.Combine("interop", "zig_vectors", name);
    var bytes = File.ReadAllBytes(path);
    var actual = MemoryPackSerializer.Deserialize<T>(bytes);
    if (!EqualsValue(expected, actual))
        throw new InvalidOperationException($"Value mismatch for {name}");
    var roundTrip = MemoryPackSerializer.Serialize(actual);
    if (!bytes.AsSpan().SequenceEqual(roundTrip))
        throw new InvalidOperationException($"Byte mismatch for {name}");
}

static bool EqualsValue<T>(T left, T right)
{
    if (left is byte[] leftBytes && right is byte[] rightBytes)
        return leftBytes.AsSpan().SequenceEqual(rightBytes);
    if (left is int[] leftInts && right is int[] rightInts)
        return leftInts.AsSpan().SequenceEqual(rightInts);
    return EqualityComparer<T>.Default.Equals(left, right) ||
        (left is BasicObject lb && right is BasicObject rb && lb.Id == rb.Id && lb.Name == rb.Name) ||
        (left is NestedObject ln && right is NestedObject rn && ln.Inner?.Id == rn.Inner?.Id &&
            ln.Inner?.Name == rn.Inner?.Name && EqualsValue(ln.Values, rn.Values)) ||
        (left is RichObject lr && right is RichObject rr && lr.Id == rr.Id && lr.Name == rr.Name &&
            lr.Level == rr.Level && EqualsValue(lr.Data, rr.Data) && EqualsValue(lr.Child, rr.Child));
}
}
