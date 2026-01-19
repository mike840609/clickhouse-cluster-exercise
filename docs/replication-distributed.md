# Replication and Distributed Queries

Understanding how ClickHouse replicates data and distributes queries across nodes.

## Replication Overview

| Aspect | Single Node | Replicated (This Cluster) |
|--------|-------------|---------------------------|
| **Data safety** | Single point of failure | Data survives node loss |
| **Read scaling** | Limited to one node | Queries can hit any replica |
| **Write scaling** | Single node writes | Writes go to any replica, sync'd automatically |
| **Engine** | `MergeTree` | `ReplicatedMergeTree` |
| **Requirements** | None | ClickHouse Keeper (or ZooKeeper) |

## Shards vs Replicas

```
This Cluster: 1 Shard, 3 Replicas

┌─────────────────────────────────────────┐
│              Shard 1                    │
│  ┌───────────┬───────────┬───────────┐  │
│  │ Replica 1 │ Replica 2 │ Replica 3 │  │
│  │clickhouse01│clickhouse02│clickhouse03│ │
│  │  (same)   │  (same)   │  (same)   │  │
│  │   data    │   data    │   data    │  │
│  └───────────┴───────────┴───────────┘  │
└─────────────────────────────────────────┘
```

| Concept | Purpose | This Cluster |
|---------|---------|--------------|
| **Shard** | Horizontal partitioning (different data) | 1 shard (all data on all nodes) |
| **Replica** | Same data, different node | 3 replicas (clickhouse01/02/03) |

**When to add shards:** When data is too large for one node
**When to add replicas:** When you need more read capacity or fault tolerance

## Creating Replicated Tables

### Basic Syntax

```sql
CREATE TABLE events ON CLUSTER default (
    id UInt64,
    event_type String,
    timestamp DateTime,
    user_id UInt32
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/events',  -- Keeper path (unique per table)
    '{replica}'                            -- Replica name (unique per node)
)
ORDER BY (timestamp, id);
```

### Understanding the Parameters

**Keeper Path:** `/clickhouse/tables/{shard}/events`
- Must be unique per table
- `{shard}` macro expands to `1` (from macros.xml)
- All replicas of the same table share this path

**Replica Name:** `{replica}`
- Must be unique per node
- Expands to `clickhouse01`, `clickhouse02`, or `clickhouse03`

### ON CLUSTER Keyword

```sql
-- Creates table on ALL nodes in one command
CREATE TABLE events ON CLUSTER default (...)

-- Without ON CLUSTER, you'd need to run on each node separately
-- (error-prone, not recommended)
```

### What NOT to Do

```sql
-- BAD: Different paths = separate tables, NOT replicas!
-- On clickhouse01:
CREATE TABLE events ENGINE = ReplicatedMergeTree('/path/A/events', 'r1') ...
-- On clickhouse02:
CREATE TABLE events ENGINE = ReplicatedMergeTree('/path/B/events', 'r2') ...
-- These are NOT replicas of each other!

-- GOOD: Same path, different replica names
CREATE TABLE events ON CLUSTER default
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}') ...
```

## How Replication Works

### Write Path

1. Client sends INSERT to any replica (e.g., clickhouse01)
2. That replica writes data locally
3. Replica records the write in ClickHouse Keeper
4. Other replicas see the log entry and pull the data

```sql
-- Insert on clickhouse01
INSERT INTO events VALUES (1, 'click', now(), 100);

-- Data automatically appears on clickhouse02 and clickhouse03
```

### Read Path

- Any replica can serve read queries
- No coordination needed for reads
- All replicas return the same data (eventually consistent)

```sql
-- Query any node - same results
-- clickhouse01:
SELECT count() FROM events;
-- clickhouse02:
SELECT count() FROM events;
-- clickhouse03:
SELECT count() FROM events;
```

## Checking Replication Status

### Replica Health

```sql
-- Check all replicated tables
SELECT
    database,
    table,
    is_leader,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue,
    absolute_delay
FROM system.replicas
WHERE database = 'default';
```

**Healthy indicators:**
- `active_replicas = total_replicas` (all nodes online)
- `queue_size = 0` (no pending replication)
- `absolute_delay = 0` (no lag)

### Replication Queue

```sql
-- Check pending replication tasks
SELECT
    database,
    table,
    type,
    create_time,
    source_replica,
    num_tries,
    last_exception
FROM system.replication_queue
ORDER BY create_time;
```

### Keeper Status

```sql
-- Verify ClickHouse Keeper is healthy
SELECT * FROM system.keeper_raft_state;

-- Check Keeper connections
SELECT * FROM system.zookeeper WHERE path = '/clickhouse';
```

## Common Scenarios

### Scenario 1: Node Goes Down

```sql
-- Insert while clickhouse03 is down
INSERT INTO events VALUES (2, 'view', now(), 200);

-- Data is on clickhouse01 and clickhouse02
-- When clickhouse03 comes back, it automatically syncs
```

**What happens:**
1. Writes continue to available replicas
2. Downed replica catches up when it returns
3. No data loss (as long as 1 replica survives)

### Scenario 2: Detecting Replication Lag

```sql
-- Check if any replica is behind
SELECT
    table,
    replica_name,
    absolute_delay,
    queue_size
FROM system.replicas
WHERE absolute_delay > 0 OR queue_size > 0;
```

**Common causes:**
- Network issues between nodes
- Slow disk on one replica
- Keeper connectivity problems

### Scenario 3: Verifying Data Consistency

```sql
-- Check row counts on each replica
SELECT
    hostName() as node,
    count() as rows
FROM events;

-- Run on each node or use Distributed table
```

## Quick Reference

| Task | Command/Query |
|------|---------------|
| Create replicated table | `CREATE TABLE ... ON CLUSTER default ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/name', '{replica}')` |
| Check replica status | `SELECT * FROM system.replicas` |
| Check replication queue | `SELECT * FROM system.replication_queue` |
| Check Keeper status | `SELECT * FROM system.keeper_raft_state` |
| Force sync (rarely needed) | `SYSTEM SYNC REPLICA table_name` |
| Check which node you're on | `SELECT hostName()` |
