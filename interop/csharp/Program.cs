using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Collections;
using System.Collections.Immutable;
using System.Collections.ObjectModel;
using System.Numerics;
using System.Net;
using System.Globalization;
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

[MemoryPackable]
public partial class NumberMessage : IMessage
{
    public int Value { get; set; }
}

[MemoryPackable]
public partial class TextMessage : IMessage
{
    public string? Value { get; set; }
}

[MemoryPackable]
public partial class LargeMessage : IMessage
{
    public int Value { get; set; }
}

[MemoryPackable(GenerateType.NoGenerate)]
public partial interface IMessage
{
}

[MemoryPackUnionFormatter(typeof(IMessage))]
[MemoryPackUnion(0, typeof(NumberMessage))]
[MemoryPackUnion(1, typeof(TextMessage))]
[MemoryPackUnion(300, typeof(LargeMessage))]
public partial class MessageUnionFormatter
{
}

[MemoryPackable(GenerateType.VersionTolerant)]
public partial class VersionedObject
{
    [MemoryPackOrder(0)]
    public int Id { get; set; }
    [MemoryPackOrder(1)]
    public string? Name { get; set; }
}

[MemoryPackable(GenerateType.CircularReference)]
public partial class CircularObject
{
    [MemoryPackOrder(0)]
    public int Value { get; set; }
    [MemoryPackOrder(1)]
    public CircularObject? Next { get; set; }
}

[MemoryPackable(SerializeLayout.Explicit)]
public partial class ExplicitObject
{
    [MemoryPackOrder(0)]
    public int First { get; set; }
    [MemoryPackOrder(1)]
    public string? Third { get; set; }
}

[MemoryPackable]
public partial class IgnoreObject
{
    public int Kept { get; set; }
    [MemoryPackIgnore]
    public int Ignored { get; set; }
}

[MemoryPackable]
public partial class IncludeObject
{
    public int Kept { get; set; }
    [MemoryPackInclude]
    private int included;

    public IncludeObject(int kept, int included)
    {
        Kept = kept;
        this.included = included;
    }

    public int GetIncluded() => included;
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
    Write("tuple.bin", new KeyValuePair<int, string>(7, "seven"));
    Write("dict_empty.bin", new Dictionary<int, string>());
    Write("dict_single.bin", new Dictionary<int, string> { [1] = "one" });
    Write("dict_multi.bin", new Dictionary<int, string> { [1] = "one", [2] = "two" });
    WriteUnion("union_small.bin", new TextMessage { Value = "hello" });
    WriteUnion("union_large.bin", new LargeMessage { Value = 300 });
    Write("versioned.bin", new VersionedObject { Id = 7, Name = "new" });
    var circular = new CircularObject { Value = 42 };
    circular.Next = circular;
    Write("circular.bin", circular);
    Write("guid.bin", Guid.Parse("00112233-4455-6677-8899-aabbccddeeff"));
    Write("datetime.bin", new DateTime(638000000000000000, DateTimeKind.Utc));
    Write("datetimeoffset.bin", new DateTimeOffset(2023, 4, 5, 6, 7, 8, TimeSpan.FromHours(5.5)));
    Write("timespan.bin", TimeSpan.FromTicks(123456789));
    Write("decimal.bin", 123456789.0123m);
    Write("version.bin", new Version(1, 2));
    Write("uri.bin", new Uri("https://example.com/a?q=1"));
    Write("explicit.bin", new ExplicitObject { First = 7, Third = "gap" });
    Write("int128.bin", Int128.Parse("-123456789012345678901234567890"));
    Write("uint128.bin", UInt128.Parse("340282366920938463463374607431768211455"));
    Write("half.bin", (Half)1.5f);
    Write("array_2d.bin", new[,] { { 1, 2 }, { 3, 4 } });
    Write("immutable_array.bin", ImmutableArray.Create(5, 6, 7));
    Write("hash_set.bin", new HashSet<int> { 5, 6, 7 });
    Write("ignore.bin", new IgnoreObject { Kept = 7, Ignored = 99 });
    Write("include.bin", new IncludeObject(7, 11));
    Write("array_3d.bin", new[,,] { { { 1, 2 }, { 3, 4 } }, { { 5, 6 }, { 7, 8 } } });
    Write("tuple3.bin", (7, "seven", true));
    Write("tuple4.bin", (7, "seven", true, 1.5f));
    Write("date_only.bin", new DateOnly(2023, 4, 5));
    Write("time_only.bin", new TimeOnly(6, 7, 8));
    Write("linked_list.bin", new LinkedList<int>(new[] { 5, 6, 7 }));
    Write("queue.bin", new Queue<int>(new[] { 5, 6, 7 }));
    var stack = new Stack<int>();
    stack.Push(5);
    stack.Push(6);
    stack.Push(7);
    Write("stack.bin", stack);
    Write("sorted_dictionary.bin", new SortedDictionary<int, string> { [1] = "one", [2] = "two" });
    Write("read_only_collection.bin", new ReadOnlyCollection<int>(new[] { 5, 6, 7 }));
    var bits = new BitArray(new[] { true, false, true, true, false, false, true, true, true, false });
    Write("bit_array.bin", bits);
    Write("string_builder.bin", new StringBuilder("hello builder"));
    Write("complex.bin", new Complex(1.5, -2.25));
    Write("culture_info.bin", CultureInfo.GetCultureInfo("en-US"));
    Write("type_name.bin", typeof(string));
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
    Verify("tuple.bin", new KeyValuePair<int, string>(7, "seven"));
    Verify("dict_empty.bin", new Dictionary<int, string>(), strictBytes: true);
    Verify("dict_single.bin", new Dictionary<int, string> { [1] = "one" }, strictBytes: true);
    Verify("dict_multi.bin", new Dictionary<int, string> { [1] = "one", [2] = "two" }, strictBytes: false);
    VerifyUnion("union_small.bin", new TextMessage { Value = "hello" });
    VerifyUnion("union_large.bin", new LargeMessage { Value = 300 });
    Verify("versioned.bin", new VersionedObject { Id = 7, Name = "new" });
    var circular = new CircularObject { Value = 42 };
    circular.Next = circular;
    Verify("circular.bin", circular, strictBytes: true);
    Verify("guid.bin", Guid.Parse("00112233-4455-6677-8899-aabbccddeeff"));
    Verify("datetime.bin", new DateTime(638000000000000000, DateTimeKind.Utc));
    Verify("datetimeoffset.bin", new DateTimeOffset(2023, 4, 5, 6, 7, 8, TimeSpan.FromHours(5.5)));
    Verify("timespan.bin", TimeSpan.FromTicks(123456789));
    Verify("decimal.bin", 123456789.0123m);
    Verify("version.bin", new Version(1, 2));
    Verify("uri.bin", new Uri("https://example.com/a?q=1"));
    Verify("explicit.bin", new ExplicitObject { First = 7, Third = "gap" });
    Verify("int128.bin", Int128.Parse("-123456789012345678901234567890"));
    Verify("uint128.bin", UInt128.Parse("340282366920938463463374607431768211455"));
    Verify("half.bin", (Half)1.5f);
    Verify("array_2d.bin", new[,] { { 1, 2 }, { 3, 4 } });
    Verify("immutable_array.bin", ImmutableArray.Create(5, 6, 7));
    Verify("hash_set.bin", new HashSet<int> { 5, 6, 7 }, strictBytes: false);
    Verify("ignore.bin", new IgnoreObject { Kept = 7, Ignored = 0 });
    Verify("include.bin", new IncludeObject(7, 11));
    Verify("array_3d.bin", new[,,] { { { 1, 2 }, { 3, 4 } }, { { 5, 6 }, { 7, 8 } } });
    Verify("tuple3.bin", (7, "seven", true));
    Verify("tuple4.bin", (7, "seven", true, 1.5f));
    Verify("date_only.bin", new DateOnly(2023, 4, 5));
    Verify("time_only.bin", new TimeOnly(6, 7, 8));
    Verify("linked_list.bin", new LinkedList<int>(new[] { 5, 6, 7 }));
    Verify("queue.bin", new Queue<int>(new[] { 5, 6, 7 }));
    Verify("stack.bin", new Stack<int>(new[] { 5, 6, 7 }), strictBytes: false);
    Verify("sorted_dictionary.bin", new SortedDictionary<int, string> { [1] = "one", [2] = "two" }, strictBytes: false);
    Verify("read_only_collection.bin", new ReadOnlyCollection<int>(new[] { 5, 6, 7 }));
    Verify("bit_array.bin", new BitArray(new[] { true, false, true, true, false, false, true, true, true, false }));
    Verify("string_builder.bin", new StringBuilder("hello builder"));
    Verify("complex.bin", new Complex(1.5, -2.25));
    Verify("culture_info.bin", CultureInfo.GetCultureInfo("en-US"));
    Verify("type_name.bin", typeof(string));
}

static void Write<T>(string name, T value)
{
    File.WriteAllBytes(Path.Combine(VectorDir, name), MemoryPackSerializer.Serialize(value));
}

static void WriteUnion(string name, IMessage value)
{
    File.WriteAllBytes(Path.Combine(VectorDir, name), MemoryPackSerializer.Serialize<IMessage>(value));
}

static void Verify<T>(string name, T expected, bool strictBytes = true)
{
    var path = Path.Combine("interop", "zig_vectors", name);
    var bytes = File.ReadAllBytes(path);
    var actual = MemoryPackSerializer.Deserialize<T>(bytes);
    if (!EqualsValue(expected, actual))
        throw new InvalidOperationException($"Value mismatch for {name}");
    var roundTrip = MemoryPackSerializer.Serialize(actual);
    if (strictBytes && !bytes.AsSpan().SequenceEqual(roundTrip))
        throw new InvalidOperationException($"Byte mismatch for {name}");
}

static void VerifyUnion(string name, IMessage expected)
{
    var path = Path.Combine("interop", "zig_vectors", name);
    var bytes = File.ReadAllBytes(path);
    var actual = MemoryPackSerializer.Deserialize<IMessage>(bytes);
    if (!EqualsMessage(expected, actual))
        throw new InvalidOperationException($"Union value mismatch for {name}");
    var roundTrip = MemoryPackSerializer.Serialize<IMessage>(actual);
    if (!bytes.AsSpan().SequenceEqual(roundTrip))
        throw new InvalidOperationException($"Union byte mismatch for {name}");
}

static bool EqualsMessage(IMessage? left, IMessage? right)
{
    return (left, right) switch
    {
        (NumberMessage a, NumberMessage b) => a.Value == b.Value,
        (TextMessage a, TextMessage b) => a.Value == b.Value,
        (LargeMessage a, LargeMessage b) => a.Value == b.Value,
        _ => false,
    };
}

static bool EqualsValue<T>(T left, T right)
{
    if (left is byte[] leftBytes && right is byte[] rightBytes)
        return leftBytes.AsSpan().SequenceEqual(rightBytes);
    if (left is int[] leftInts && right is int[] rightInts)
        return leftInts.AsSpan().SequenceEqual(rightInts);
    if (left is int[,] leftMatrix && right is int[,] rightMatrix)
        return leftMatrix.GetLength(0) == rightMatrix.GetLength(0) &&
            leftMatrix.GetLength(1) == rightMatrix.GetLength(1) &&
            leftMatrix.Cast<int>().SequenceEqual(rightMatrix.Cast<int>());
    if (left is int[,,] leftCube && right is int[,,] rightCube)
        return leftCube.GetLength(0) == rightCube.GetLength(0) &&
            leftCube.GetLength(1) == rightCube.GetLength(1) &&
            leftCube.GetLength(2) == rightCube.GetLength(2) &&
            leftCube.Cast<int>().SequenceEqual(rightCube.Cast<int>());
    if (left is ImmutableArray<int> leftImmutable && right is ImmutableArray<int> rightImmutable)
        return leftImmutable.SequenceEqual(rightImmutable);
    if (left is HashSet<int> leftSet && right is HashSet<int> rightSet)
        return leftSet.SetEquals(rightSet);
    if (left is LinkedList<int> leftLinked && right is LinkedList<int> rightLinked)
        return leftLinked.SequenceEqual(rightLinked);
    if (left is Queue<int> leftQueue && right is Queue<int> rightQueue)
        return leftQueue.SequenceEqual(rightQueue);
    if (left is Stack<int> leftStack && right is Stack<int> rightStack)
        return leftStack.SequenceEqual(rightStack);
    if (left is ReadOnlyCollection<int> leftReadOnly && right is ReadOnlyCollection<int> rightReadOnly)
        return leftReadOnly.SequenceEqual(rightReadOnly);
    if (left is SortedDictionary<int, string> leftSorted && right is SortedDictionary<int, string> rightSorted)
        return leftSorted.SequenceEqual(rightSorted);
    if (left is BitArray leftBits && right is BitArray rightBits)
        return leftBits.Cast<bool>().SequenceEqual(rightBits.Cast<bool>());
    if (left is StringBuilder leftBuilder && right is StringBuilder rightBuilder)
        return leftBuilder.ToString() == rightBuilder.ToString();
    if (left is IPAddress leftAddress && right is IPAddress rightAddress)
        return leftAddress.GetAddressBytes().AsSpan().SequenceEqual(rightAddress.GetAddressBytes());
    if (left is CultureInfo leftCulture && right is CultureInfo rightCulture)
        return leftCulture.Name == rightCulture.Name;
    if (left is Type leftType && right is Type rightType)
        return leftType == rightType;
    if (left is Dictionary<int, string> leftDict && right is Dictionary<int, string> rightDict)
        return leftDict.Count == rightDict.Count && leftDict.All(pair =>
            rightDict.TryGetValue(pair.Key, out var value) && value == pair.Value);
    return EqualityComparer<T>.Default.Equals(left, right) ||
        (left is BasicObject lb && right is BasicObject rb && lb.Id == rb.Id && lb.Name == rb.Name) ||
        (left is NestedObject ln && right is NestedObject rn && ln.Inner?.Id == rn.Inner?.Id &&
            ln.Inner?.Name == rn.Inner?.Name && EqualsValue(ln.Values, rn.Values)) ||
        (left is RichObject lr && right is RichObject rr && lr.Id == rr.Id && lr.Name == rr.Name &&
            lr.Level == rr.Level && EqualsValue(lr.Data, rr.Data) && EqualsValue(lr.Child, rr.Child)) ||
        (left is VersionedObject lv && right is VersionedObject rv && lv.Id == rv.Id && lv.Name == rv.Name) ||
        (left is CircularObject lc && right is CircularObject rc && lc.Value == rc.Value &&
            rc.Next == rc) ||
        (left is ExplicitObject le && right is ExplicitObject re && le.First == re.First && le.Third == re.Third) ||
        (left is IgnoreObject li && right is IgnoreObject ri && li.Kept == ri.Kept && ri.Ignored == 0) ||
        (left is IncludeObject linc && right is IncludeObject rinc &&
            linc.Kept == rinc.Kept && linc.GetIncluded() == rinc.GetIncluded());
}
}
