# Parallel Dispatch Guidelines

When facing multiple independent operations, dispatch them in parallel using the Agent tool or multiple tool calls in a single response. This reduces wall-clock time and improves throughput.

## When to Parallelize

- **Independent research** — searching for multiple unrelated patterns, reading unrelated files, fetching from different URLs
- **Independent validation** — running lint + typecheck + tests simultaneously when they don't depend on each other
- **Multi-file search** — searching for a class definition across multiple possible locations
- **Parallel file operations** — reading several files that are all needed for a single decision
- **Subagent dispatch** — launching multiple Agent tool calls for tasks that don't share state (e.g., one agent researches backend, another researches frontend)

## When NOT to Parallelize

- **Sequential dependencies** — operation B needs the result of operation A (e.g., find the file, then read it)
- **Shared state mutation** — two operations that write to the same file or branch
- **Order-sensitive operations** — git commit then push, create file then edit it
- **Resource contention** — two Docker builds competing for the same build cache
- **Confirmation required** — destructive operations that need user approval before proceeding

## Standard Patterns

### Pattern 1: Parallel Research

When you need to understand multiple aspects of a problem before acting:

```
# Instead of sequential:
1. Search for config file → 2. Read config → 3. Search for usage → 4. Read usage

# Parallelize independent searches:
1. [Search for config file] + [Search for usage patterns]  (parallel)
2. [Read config] + [Read usage files]                       (parallel, after step 1)
3. Make decision based on both
```

### Pattern 2: Parallel Validation

After making changes, validate multiple dimensions at once:

```
# Instead of sequential:
1. Run lint → 2. Run typecheck → 3. Run tests

# Parallelize:
1. [Run lint] + [Run typecheck] + [Run tests]  (all parallel)
2. Fix any failures
```

### Pattern 3: Parallel Search

When searching for something that could be in multiple locations:

```
# Instead of trying one location at a time:
1. Glob for *.ts → 2. Glob for *.tsx → 3. Grep for pattern

# Parallelize:
1. [Glob *.ts] + [Glob *.tsx] + [Grep for pattern]  (all parallel)
2. Merge results
```

### Pattern 4: Parallel File Operations

When you need to read multiple files to make a decision:

```
# Instead of sequential reads:
1. Read package.json → 2. Read tsconfig.json → 3. Read .eslintrc

# Parallelize:
1. [Read package.json] + [Read tsconfig.json] + [Read .eslintrc]  (all parallel)
2. Analyze together
```

## Decision Checklist

Before dispatching in parallel, confirm:

1. **No data dependency** — Does operation B need the output of operation A? If yes, serialize.
2. **No write conflicts** — Do both operations modify the same resource? If yes, serialize.
3. **No ordering requirement** — Does the sequence matter for correctness? If yes, serialize.
4. **Worth the overhead** — Are the operations slow enough that parallelism saves meaningful time? For two instant operations, parallelism adds complexity without benefit.

## Anti-Patterns

| Anti-Pattern | Problem | Fix |
|---|---|---|
| Parallel writes to same file | Race condition, last write wins | Serialize writes, parallelize reads |
| Parallel git operations | Index lock conflicts | Serialize all git mutations |
| Dispatching agent for trivial lookup | Overhead exceeds savings | Use Glob/Grep/Read directly |
| Parallelizing 2 fast operations | No meaningful speedup | Just run sequentially |
| Parallel edits then single commit | Merge conflicts in staging | Edit sequentially, commit once |
