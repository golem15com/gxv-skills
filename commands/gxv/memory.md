---
description: Search or store project memory
argument-hint: <search|store> [query or content]
allowed-tools: Bash
---

# /gxv:memory

Interact with the project's persistent memory system. Memory is stored per-project and shared across all agents.

## Arguments

- **action** (required): `search` or `store`
- **content** (required): For `search`, the query string. For `store`, the content to memorize.

## Usage Examples

```
/gxv:memory search "how does the payment flow work"
/gxv:memory store "The task FSM requires optimistic locking via version column"
```

## Process

### Step 1: Parse arguments

Extract the action (`search` or `store`) and the remaining text as content from `$ARGUMENTS`.

**If no arguments or invalid action:**
```
Usage: /gxv:memory <search|store> [query or content]

Examples:
  /gxv:memory search "authentication flow"
  /gxv:memory store "API rate limit is 100 req/min"
```
STOP here.

### Step 2: Execute via MCP tool

**For `search`:**

Use the `memory_search` MCP tool:
```
mcp__golemxv__memory_search({ query: "THE_QUERY", max_results: 10 })
```

Display results as:

```
## Memory Search Results

Found [count] results for "[query]":

### [#id] [category] (score: [score])
[content]
*Source: [source] | Tags: [tags] | Stored: [created_at]*

---
```

If no results: "No memories found matching your query."

**For `store`:**

Use the `memory_store` MCP tool. Before storing, ask the user for optional metadata:

- **Category** (default: `general`): context, pattern, decision, debug, or general
- **Tags** (optional): comma-separated tags

Then call:
```
mcp__golemxv__memory_store({ content: "THE_CONTENT", category: "CATEGORY", tags: ["tag1", "tag2"] })
```

Display confirmation:

```
## Memory Stored

**ID:** [id]
**Category:** [category]
**Tags:** [tags]
**Content:** [first 200 chars]...

This memory is now available to all agents working on this project.
```

### Important Notes

- Memory is project-scoped -- it persists across sessions and is shared between all agents
- Use `context` category for work summaries and situational knowledge
- Use `pattern` category for recurring solutions and conventions
- Use `decision` category for architectural decisions and rationale
- Use `debug` category for debugging insights and gotchas
- Agents automatically search memory at session start and store work summaries on checkout
