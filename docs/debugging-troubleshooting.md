# Debugging and Troubleshooting

How to investigate slow queries, understand query execution, and diagnose common issues.

## Understanding Query Execution with EXPLAIN

### EXPLAIN Types

| Type | Shows | Use When |
|------|-------|----------|
| `EXPLAIN` | Basic execution plan | Quick overview |
| `EXPLAIN AST` | Abstract Syntax Tree | Understanding query parsing |
| `EXPLAIN SYNTAX` | Optimized query | Seeing how ClickHouse rewrites your query |
| `EXPLAIN PLAN` | Detailed execution steps | Finding bottlenecks |
| `EXPLAIN PIPELINE` | Execution pipeline | Understanding parallelism |
| `EXPLAIN ESTIMATE` | Estimated rows/bytes | Quick size check before running |

### Examples

```sql
-- Basic EXPLAIN
EXPLAIN
SELECT count() FROM events WHERE timestamp > '2024-01-01';

-- EXPLAIN ESTIMATE - quick row/size estimate (doesn't run query)
EXPLAIN ESTIMATE
SELECT * FROM events WHERE user_id = 123;

-- EXPLAIN PLAN with details
EXPLAIN PLAN header=1, actions=1
SELECT user_id, count() FROM events GROUP BY user_id;

-- EXPLAIN PIPELINE - see parallel execution
EXPLAIN PIPELINE
SELECT user_id, count() FROM events GROUP BY user_id;
```

## Essential System Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `system.query_log` | Query history | `query`, `read_rows`, `memory_usage`, `query_duration_ms` |
| `system.processes` | Running queries | `query`, `elapsed`, `read_rows` |
| `system.parts` | Table parts on disk | `table`, `rows`, `bytes`, `active` |
| `system.mutations` | UPDATE/DELETE progress | `table`, `is_done`, `parts_to_do` |
| `system.replicas` | Replication status | `table`, `is_leader`, `queue_size` |
| `system.merges` | Ongoing merges | `table`, `progress`, `elapsed` |

## Diagnosing Slow Queries

### Step 1: Find the Slow Query

```sql
-- Recent slow queries (>1 second)
SELECT
    query_start_time,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) as data_read,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 200) as query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND query_start_time > now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

### Step 2: Analyze with EXPLAIN

```sql
-- Run EXPLAIN on the slow query
EXPLAIN PLAN
SELECT ... -- your slow query here
```

### Step 3: Check What Was Scanned

Look at `read_rows` and `read_bytes` in query_log:
- **High read_rows** = Scanning too many rows (index not used)
- **High memory_usage** = Large result set or JOIN issues

### Step 4: Identify the Cause

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| High read_rows | Full table scan | Fix ORDER BY or add proper filtering |
| High memory_usage | Large JOINs or result set | Add LIMIT, optimize JOIN |
| Slow despite few rows | Mutation in progress | Wait or check `system.mutations` |
| Query stuck | Lock or heavy merge | Check `system.processes` |

## Common Gotchas

### 1. ORDER BY Mismatch

The table's ORDER BY determines what queries are fast:

```sql
-- Table with ORDER BY timestamp
CREATE TABLE events (
    user_id UInt32,
    timestamp DateTime,
    event_type String
) ENGINE = MergeTree()
ORDER BY timestamp;

-- FAST: Uses the index
SELECT * FROM events WHERE timestamp > '2024-01-01';

-- SLOW: Can't use index efficiently (full scan!)
SELECT * FROM events WHERE user_id = 123;
```

**Fix:** Recreate table with ORDER BY matching your query patterns:
```sql
ORDER BY (user_id, timestamp)  -- Now both queries are fast
```

### 2. FINAL Keyword Performance

`FINAL` forces deduplication at query time - can be very slow:

```sql
-- SLOW: Deduplicates on read
SELECT * FROM users FINAL WHERE id = 123;

-- FASTER alternatives:
-- 1. Use DISTINCT
SELECT DISTINCT * FROM users WHERE id = 123;

-- 2. Use argMax for latest row
SELECT argMax(name, updated_at) FROM users WHERE id = 123;

-- 3. Run OPTIMIZE to merge parts
OPTIMIZE TABLE users FINAL;
```

### 3. Too Many Parts

Each INSERT creates a new "part". Too many = slow queries.

```sql
-- Check parts count
SELECT
    table,
    count() as parts,
    sum(rows) as total_rows
FROM system.parts
WHERE active AND database = 'default'
GROUP BY table
HAVING parts > 100
ORDER BY parts DESC;
```

**Warning signs:** > 300 parts per table

**Fix:**
1. Batch your INSERTs (1000+ rows per INSERT)
2. Wait for background merges
3. Force merge: `OPTIMIZE TABLE events FINAL;`

### 4. Mutation Queue Buildup

UPDATE/DELETE operations queue up and run in background:

```sql
-- Check mutation progress
SELECT
    table,
    mutation_id,
    command,
    is_done,
    parts_to_do,
    latest_fail_reason
FROM system.mutations
WHERE NOT is_done
ORDER BY create_time;
```

**If stuck:** Check `latest_fail_reason` for errors.

### 5. Memory Exceeded

```sql
-- Find memory-hungry queries
SELECT
    query_start_time,
    formatReadableSize(memory_usage) as peak_memory,
    read_rows,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND memory_usage > 1000000000  -- > 1GB
ORDER BY memory_usage DESC
LIMIT 10;
```

**Common causes:**
- Large JOINs (right table loaded into memory)
- GROUP BY with high cardinality
- No LIMIT on large result sets

**Fixes:**
```sql
-- Add LIMIT
SELECT * FROM events LIMIT 1000;

-- Select fewer columns
SELECT id, name FROM users;  -- Not SELECT *

-- Increase limit (if you have memory)
SET max_memory_usage = 20000000000;  -- 20GB
```

## Troubleshooting Checklist

### Query is Slow

- [ ] Run EXPLAIN - is it scanning too many rows?
- [ ] Check if table ORDER BY matches query WHERE clause
- [ ] Look for JOINs with large right-side tables
- [ ] Check if FINAL is being used
- [ ] Verify partitions are being pruned (if partitioned)

### Insert is Slow

- [ ] Are you batching? (1000+ rows per INSERT)
- [ ] Check `system.parts` for too many parts
- [ ] Check `system.merges` for ongoing merges

### Replication Issues

- [ ] Check `system.replicas` - is `queue_size` > 0?
- [ ] Verify Keeper is healthy: `system.keeper_raft_state`
- [ ] Check network connectivity between nodes

## Useful Diagnostic Queries

### Currently Running Queries

```sql
SELECT
    query_id,
    user,
    elapsed,
    read_rows,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 100) as query_preview
FROM system.processes
WHERE is_initial_query
ORDER BY elapsed DESC;

-- Kill a long-running query
KILL QUERY WHERE query_id = 'your-query-id';
```

### Table Health Check

```sql
SELECT
    table,
    sum(rows) as total_rows,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count() as parts,
    max(modification_time) as last_modified
FROM system.parts
WHERE active AND database = 'default'
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC;
```

### Cluster Health

```sql
-- Replication status
SELECT
    database,
    table,
    replica_name,
    is_leader,
    active_replicas,
    queue_size,
    absolute_delay
FROM system.replicas;

-- Keeper status
SELECT * FROM system.keeper_raft_state;
```

## Quick Reference: Error Messages

| Error | Meaning | Solution |
|-------|---------|----------|
| "Memory limit exceeded" | Query needs too much RAM | Add LIMIT, optimize JOINs, increase `max_memory_usage` |
| "Too many parts" | Too many small INSERTs | Batch inserts, wait for merges |
| "Table is in readonly mode" | Keeper connection lost | Check Keeper, wait for recovery |
| "Replica is not active" | Replication issue | Check `system.replicas`, verify network |
| "Cannot reserve X bytes" | Out of disk space | Free disk space, check data retention |
| "DB::Exception: Unknown table" | Table doesn't exist | Check database name, run `SHOW TABLES` |
