using MemoryPack;

if (args.Length != 2 && args.Length != 3)
    throw new ArgumentException("usage: write <output> | mutate <input> <output>");

if (args[0] == "write")
{
    var initialProfile = new PlayerProfile
    {
        Id = 1001,
        Name = "Ada",
        Level = PlayerLevel.Veteran,
        Experience = 123450,
        LastLogin = 12345,
        Inventory =
        [
            new InventoryItem { Name = "Moonblade", Count = 1, Rarity = Rarity.Legendary },
            new InventoryItem { Name = "Potion", Count = 5, Rarity = Rarity.Common },
        ],
        RecentEvents =
        [
            new LevelUpEvent { Level = 2 },
            new ItemFoundEvent { ItemName = "Moonblade", Count = 1 },
        ],
    };
    var initialOutput = MemoryPackSerializer.Serialize(initialProfile);
    File.WriteAllBytes(args[1], initialOutput);
    Console.WriteLine($"C# wrote profile: {initialOutput.Length} bytes -> {args[1]}");
    return;
}

if (args[0] != "mutate")
    throw new ArgumentException("usage: write <output> | mutate <input> <output>");

var input = File.ReadAllBytes(args[1]);
var profile = MemoryPackSerializer.Deserialize<PlayerProfile>(input)
    ?? throw new InvalidDataException("profile was null");

Console.WriteLine($"C# read profile: id={profile.Id}, name={profile.Name}, level={profile.Level}, xp={profile.Experience}, lastLoginDay={profile.LastLogin}, inventory={profile.Inventory.Length}, events={profile.RecentEvents.Length}");
foreach (var item in profile.Inventory)
    Console.WriteLine($"  inventory: {item.Name} x{item.Count} ({item.Rarity})");
foreach (var item in profile.RecentEvents)
    Console.WriteLine($"  event: {item}");

profile.Level = PlayerLevel.Champion;
profile.Experience += 2500;
profile.Inventory = profile.Inventory
    .Append(new InventoryItem { Name = "Phoenix Down", Count = 2, Rarity = Rarity.Rare })
    .ToArray();
profile.RecentEvents = profile.RecentEvents
    .Append(new LevelUpEvent { Level = 3 })
    .ToArray();

var output = MemoryPackSerializer.Serialize(profile);
File.WriteAllBytes(args[2], output);
Console.WriteLine($"C# mutated profile: level={profile.Level}, xp={profile.Experience}, lastLoginDay={profile.LastLogin}, inventory={profile.Inventory.Length}, events={profile.RecentEvents.Length}");
Console.WriteLine($"  bytes written: {output.Length} -> {args[2]}");

[MemoryPackable]
public partial class PlayerProfile
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public PlayerLevel Level { get; set; }
    public long Experience { get; set; }
    public int? LastLogin { get; set; }
    public InventoryItem[] Inventory { get; set; } = Array.Empty<InventoryItem>();
    public IPlayerEvent[] RecentEvents { get; set; } = Array.Empty<IPlayerEvent>();
}

public enum PlayerLevel : byte
{
    Novice = 1,
    Veteran = 2,
    Champion = 3,
}

public enum Rarity : byte
{
    Common = 1,
    Rare = 2,
    Legendary = 3,
}

[MemoryPackable]
public partial class InventoryItem
{
    public string Name { get; set; } = "";
    public int Count { get; set; }
    public Rarity Rarity { get; set; }
}

[MemoryPackable(GenerateType.NoGenerate)]
public partial interface IPlayerEvent
{
}

[MemoryPackable]
public partial class LevelUpEvent : IPlayerEvent
{
    public int Level { get; set; }

    public override string ToString() => $"level-up -> {Level}";
}

[MemoryPackable]
public partial class ItemFoundEvent : IPlayerEvent
{
    public string ItemName { get; set; } = "";
    public int Count { get; set; }

    public override string ToString() => $"item-found {ItemName} x{Count}";
}

[MemoryPackUnionFormatter(typeof(IPlayerEvent))]
[MemoryPackUnion(0, typeof(LevelUpEvent))]
[MemoryPackUnion(1, typeof(ItemFoundEvent))]
public partial class PlayerEventUnionFormatter
{
}
