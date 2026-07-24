# Player profile: Zig ↔ C# MemoryPack

This example is a real file-based workflow:

1. Zig creates and serializes a player profile to `profile.bin`.
2. C# deserializes it with the real Cysharp/MemoryPack 1.21.3 package,
   changes the level, experience, inventory, and recent events, then writes
   `profile_updated.bin`.
3. Zig deserializes the updated file and asserts that the C# mutations are
   visible.

The schema intentionally uses only byte-stable formats already covered by the
repository's interop tests:

- Object framing for the profile and inventory items.
- `Str`/C# `string`.
- Byte-backed enums.
- Nullable `int32` login-day value (an application-defined calendar-day number).
- Arrays.
- A tagged union for recent events.

It avoids unordered dictionaries and sets, whose enumeration order is not
guaranteed to be byte-stable across languages.

## Run

From the repository root:

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/player-profile/run.sh
```

The Zig executable is also available as:

```sh
zig build example -- write examples/player-profile/profile.bin
zig build example -- read examples/player-profile/profile_updated.bin
```

## Schema

Both languages use the same declaration order:

```text
PlayerProfile
  Id: int32
  Name: string
  Level: byte enum
  Experience: int64
  LastLogin: nullable int32 (application-defined calendar-day number)
  Inventory: InventoryItem[]
  RecentEvents: IPlayerEvent[]

InventoryItem
  Name: string
  Count: int32
  Rarity: byte enum

IPlayerEvent union
  tag 0: LevelUpEvent { Level: int32 }
  tag 1: ItemFoundEvent { ItemName: string, Count: int32 }
```

## Example output

```text
=== Step 1: Zig writes profile.bin ===
Zig wrote profile: id=1001, name=Ada, level=veteran, xp=123450, lastLoginDay=12345, inventory=2, events=2
  inventory: Moonblade x1 (legendary)
  inventory: Potion x5 (common)
  event: level-up -> 2
  event: item-found Moonblade x1
  bytes written: 113 -> /.../examples/player-profile/profile.bin

=== Step 2: C# MemoryPack reads, mutates, and writes profile_updated.bin ===
C# read profile: id=1001, name=Ada, level=Veteran, xp=123450, lastLoginDay=12345, inventory=2, events=2
  inventory: Moonblade x1 (Legendary)
  inventory: Potion x5 (Common)
  event: level-up -> 2
  event: item-found Moonblade x1
C# mutated profile: level=Champion, xp=125950, lastLoginDay=12345, inventory=3, events=3
  bytes written: 145 -> /.../examples/player-profile/profile_updated.bin

=== Step 3: Zig reads profile_updated.bin ===
Zig read updated profile: id=1001, name=Ada, level=champion, xp=125950, lastLoginDay=12345, inventory=3, events=3
  inventory: Moonblade x1 (legendary)
  inventory: Potion x5 (common)
  inventory: Phoenix Down x2 (rare)
  event: level-up -> 2
  event: item-found Moonblade x1
  event: level-up -> 3
  mutation assertions: passed
```

The absolute file paths vary by checkout location.
