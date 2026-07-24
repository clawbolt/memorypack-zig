# Pure-Zig task CLI

This example is a small but complete command-line task manager written
entirely in Zig. It loads a MemoryPack-encoded store, applies one command, and
writes the updated store back to disk.

## Run

From the repository root:

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/task-cli/run.sh
```

The application is also available through the root build:

```sh
zig build task-cli -- --store tasks.bin add "Ship the release" --priority high --due 20000
zig build task-cli -- --store tasks.bin list
zig build task-cli -- --store tasks.bin done 1
zig build task-cli -- --store tasks.bin rm 1
```

Without `--store`, the default path is `tasks.bin` in the current directory.

## Store schema

The top-level store is a version-tolerant object:

```text
Store
  next_id: int32
  tasks: Task[]

Task
  id: int32
  title: Str
  priority: enum { low, normal, high }
  status: enum { open, done }
  due: nullable int32 (application-defined day number)
```

The `Task` and `Store` declarations use:

```zig
pub const memorypack_version_tolerant = true;
```

The demo first writes a legacy store whose `Task` has only the first four
fields, then loads it with the current five-field schema. The missing `due`
field is defaulted to null and the task is listed successfully. This exercises
real version-tolerant decoding rather than merely documenting the feature.

## Commands

```text
add "<title>" [--priority low|normal|high] [--due <day-number>]
list
done <id>
rm <id>
```

Each invocation loads and saves the same file, so IDs and mutations persist
across separate processes.

## Example output

```text
=== Version tolerance: legacy store loads in the current schema ===
Wrote legacy schema store: /tmp/memorypack-tasks-legacy.XXXXXX.bin
#1 [open] [high] Legacy task

=== Fresh task session ===
No tasks.
Added task #1: Write release notes
Added task #2: Review pull request
Added task #3: Plan team lunch

--- after adding three tasks ---
#1 [open] [high] Write release notes (due day 20000)
#2 [open] [normal] Review pull request
#3 [open] [low] Plan team lunch (due day 20005)

Completed task #2.
Removed task #1.

--- after completing #2 and removing #1 ---
#2 [done] [normal] Review pull request
#3 [open] [low] Plan team lunch (due day 20005)
```

The temporary path contains a randomized suffix in actual output.
