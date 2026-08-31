# How Amazon Bedrock AgentCore Memory Works

*Sessions, isolation across parallel users, short-term vs long-term memory, preferences, retention, and a scalable storage model.*

> **One-line answer to the common question:** with **managed** AgentCore Memory you do **not** create or manage any DynamoDB tables — AWS owns storage, retention, and scale. DynamoDB only enters the picture if you deliberately **self-manage** your own memory store, and even then the answer is **one** well-designed table, not many.

See the architecture diagram: [`diagrams/memory-architecture.drawio`](diagrams/memory-architecture.drawio) (open in [draw.io](https://app.diagrams.net/)).

---

## 1. The core model: memoryId + actorId + sessionId

Every AgentCore Memory API call is scoped by three identifiers:

| ID | Meaning |
|----|---------|
| `memoryId` | The memory resource (your store) |
| `actorId` | **The user** (or any principal you want to remember things about) |
| `sessionId` | **One conversation / thread** for that actor |

That triple is the whole basis for isolation and sharing. There are two tiers of memory:

- **Short-term memory** — raw `events` (the turn-by-turn messages and tool calls), stored per `(actorId, sessionId)`.
- **Long-term memory** — `records`, i.e. structured insights that a managed, **asynchronous** pipeline *extracts* from short-term events using **strategies**, and persists across sessions, organized by **namespace**.

```python
# Short-term: write a conversation turn
client.create_event(
    memoryId="my-memory-id",
    actorId="user-A",           # the user
    sessionId="s-A1",           # one conversation
    payload=[
        {"conversationalMessage": {"role": "user", "content": [{"text": "Book me an aisle seat"}]}},
        {"conversationalMessage": {"role": "assistant", "content": [{"text": "Done - aisle seat noted."}]}},
    ],
)
```

---

## 2. Parallel users — how sessions are handled concurrently

**One logical agent serves everyone at the same time.** Isolation is by **identifier, not by process or thread.** When User A and User B hit the agent simultaneously:

```python
# User A's request thread
client.create_event(memoryId=M, actorId="user-A", sessionId="s-A1", payload=[...])

# User B's request thread (running in parallel)
client.create_event(memoryId=M, actorId="user-B", sessionId="s-B1", payload=[...])
```

These write to **completely separate event streams**. There is no shared in-memory conversation buffer that could interleave User A's and User B's turns, because every call explicitly names its `actorId` and `sessionId`. That is what makes parallel access safe.

> **Design rule:** derive `actorId` from your authenticated identity (e.g. the JWT `sub` from AgentCore Identity), and generate a fresh `sessionId` per conversation. Never reuse one `sessionId` across two users.

---

## 3. Is memory shared across sessions?

**Short-term: no.** A new `sessionId` starts a fresh short-term context. If User A returns days later on session `s-A2`, that session does **not** automatically contain the raw transcript of `s-A1`.

**Long-term: yes — but only in the way you configure via the namespace template.** This is the key mechanism:

- A namespace like `users/{actorId}/facts` scopes records **per user**. User A's session `s-A2` *can* recall User A's facts learned in `s-A1`, because both resolve to `users/user-A/facts`. User B's records live in `users/user-B/facts` and are never returned to User A.
- Sharing across **users** happens **only if you deliberately omit `{actorId}`** from the namespace — e.g. `org/shared/policies`. That is an opt-in choice, not a default.

```jsonc
"strategies": [
  { "type": "SEMANTIC",        "name": "facts",  "namespaces": ["users/{actorId}/facts"] },
  { "type": "USER_PREFERENCE", "name": "prefs",  "namespaces": ["users/{actorId}/preferences"] },
  { "type": "EPISODIC",        "name": "epi",    "namespaces": ["users/{actorId}/episodes/{sessionId}"] }
]
```

**Isolation guarantee in practice:** a retrieval scoped to `users/user-A/...` can only return User A's records:

```python
result = client.retrieve_memory_records(
    memoryId="my-memory-id",
    namespace="users/user-A/facts",          # scoped to User A
    searchCriteria={"searchQuery": "seat preference", "topK": 5},
)
```

---

## 4. Short-term vs long-term: how extraction works

1. Your agent writes **events** (short-term) as the conversation happens.
2. AgentCore runs an **asynchronous, managed extraction pipeline**. The **strategies** you configured decide what to distill:
   - **SEMANTIC** — facts/knowledge as vectors (e.g. "User A flies from SEA").
   - **SUMMARIZATION** — running conversation summaries.
   - **USER_PREFERENCE** — the user's preferences/settings.
   - **EPISODIC** — episodic memories (what happened in a session), optionally with reflections.
3. The extracted **records** land in their **namespaces** as long-term memory.
4. On the next turn, the agent calls `retrieve_memory_records(...)`, scoped by namespace, and injects the top-K results into the prompt.

Extraction is **eventual**, not synchronous — the record for a fact stated now may appear shortly after, not within the same turn. You can inspect/retry extraction with the extraction-job APIs if needed.

---

## 5. How preferences are handled

Preferences are just long-term memory produced by the **`USER_PREFERENCE`** strategy into a per-user namespace (e.g. `users/{actorId}/preferences`). The loop is:

```python
# On each new turn, pull the user's known preferences and prepend them
prefs = client.retrieve_memory_records(
    memoryId="my-memory-id",
    namespace="users/user-A/preferences",
    searchCriteria={"searchQuery": "communication and seating preferences", "topK": 10},
)
# -> feed prefs into the system prompt so the agent "remembers" how User A likes things
```

Because the namespace carries `{actorId}`, User A's preferences are never leaked to User B.

---

## 6. Retention and storage — the DynamoDB question answered

### Option 1 — Managed (recommended)

With AgentCore Memory, **AWS owns the storage and scaling. You do not provision DynamoDB (or any database).** You only choose:

- **`eventExpiryDuration`** (3–365 days) — the **short-term** retention TTL. Events auto-expire after this.
- **strategies + namespaces** — what long-term records get created and how they're organized. **Long-term records persist until you explicitly delete them.**

That's the entire "how long / how scalable" story for the managed path: it scales with your traffic automatically, and retention is a single config value plus explicit deletes.

### Option 2 — Self-managed (only if you must own the store)

Choose this **only** for a hard data-ownership/residency requirement. The scalable pattern is **one single table, not many**:

| Item type | PK | SK |
|-----------|----|----|
| Short-term event | `USER#<actorId>` | `SESSION#<sessionId>#TS#<ts>` |
| Long-term record | `USER#<actorId>` | `MEM#<namespace>#<recordId>` |

- **GSI1** (`PK = namespace`, `SK = score`/`updatedAt`) for namespace-scoped retrieval and shared namespaces.
- **TTL attribute** on short-term items → DynamoDB auto-expires them (mirrors `eventExpiryDuration`).
- **On-demand capacity** → scales with parallel users with no capacity planning.
- **S3** for cold archive / compliance-grade long retention.
- A **vector store** (OpenSearch, pgvector, etc.) for embeddings + kNN semantic recall, since DynamoDB itself doesn't do vector search.
- You also own the **extraction pipeline** (e.g. SNS + S3 + a model call), embeddings, backups, and scaling.

> Why one table? A single-table design keeps every read for a user (`PK = USER#<actorId>`) on one partition, avoids cross-table joins, and scales horizontally by partition key — the standard DynamoDB approach for this access pattern. More tables would add operational overhead without benefit.

---

## 7. Quick reference

| Question | Answer |
|----------|--------|
| Parallel users collide? | No — every call is scoped by `actorId` + `sessionId`. |
| Short-term shared across sessions? | No — new `sessionId` = fresh context. |
| Long-term shared across sessions? | Yes, per-user, via `users/{actorId}/...` namespaces. |
| Shared across *users*? | Only if you omit `{actorId}` (opt-in shared namespace). |
| Preferences? | `USER_PREFERENCE` strategy → `users/{actorId}/preferences`. |
| Short-term retention? | `eventExpiryDuration` (3–365 days). |
| Long-term retention? | Persists until explicitly deleted. |
| DynamoDB tables to manage? | **Zero** on the managed path; **one** if self-managing. |

---

## 8. Accuracy notes / verify-before-you-ship

- Namespace placeholders (`{actorId}`, `{sessionId}`, `{memoryStrategyId}`), strategy types, and `eventExpiryDuration` bounds are from the AgentCore guidance; confirm against the current AWS docs for your region/account.
- Extraction is asynchronous — do not assume a just-stated fact is retrievable in the same turn. Use the extraction-job APIs to observe/retry.
- The DynamoDB single-table keys and GSI are an illustrative, common design for the self-managed path, not an AWS-prescribed schema. Adapt to your exact access patterns.
- Treat retrieved memory content as **untrusted input** (it originated from prior user turns) — sanitize before use, don't `eval` it.

### References
- AgentCore Memory overview — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.md
- Short-term memory — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/using-memory-short-term.md
- Long-term memory & strategies — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/long-term-memory-long-term.md
- Namespaces — https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/specify-long-term-memory-organization.md
- DynamoDB single-table design — https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html
