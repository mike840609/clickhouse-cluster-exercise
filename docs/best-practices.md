# ClickHouse Best Practices

Performance tips and patterns for ClickHouse.

## 1. Batch Your Inserts

**Bad:** Single-row inserts (creates many small parts)
```sql
INSERT INTO events VALUES (1, 'click', now());
INSERT INTO events VALUES (2, 'view', now());
INSERT INTO events VALUES (3, 'click', now());
```

**Good:** Batch inserts (1000+ rows per insert)
```sql
INSERT INTO events VALUES
    (1, 'click', now()),
    (2, 'view', now()),
    (3, 'click', now()),
    -- ... hundreds more rows
    (1000, 'click', now());
```

**Why:**
- Each INSERT creates a new "part" on disk
- Too many small parts = slow queries + background merge overhead
- Target: 1,000 - 100,000 rows per INSERT
- Use Buffer tables or async inserts if you can't batch client-side

## 2. Design ORDER BY for Your Queries

The `ORDER BY` clause determines:
- Physical sort order on disk
- Primary index structure
- Which queries are fast

```sql
-- If you query by user_id first, then timestamp:
-- WHERE user_id = 123 AND timestamp > '2024-01-01'
CREATE TABLE events (
    user_id UInt32,
    timestamp DateTime,
    event_type String
) ENGINE = MergeTree()
ORDER BY (user_id, timestamp);  -- Match your query patterns!

-- If you query by timestamp first:
-- WHERE timestamp > '2024-01-01' AND user_id = 123
ORDER BY (timestamp, user_id);  -- Different order!
```

**Rules:**
- Put low-cardinality columns first (e.g., `status`, `country`)
- Put frequently filtered columns early
- Put high-cardinality columns last (e.g., `user_id`, `uuid`)

## 3. Denormalize Your Data

**Traditional approach (avoid in ClickHouse):**
```sql
-- Separate tables with JOINs
SELECT o.id, o.total, u.name
FROM orders o
JOIN users u ON o.user_id = u.id;
```

**ClickHouse approach (denormalize):**
```sql
-- Store user info directly in orders table
CREATE TABLE orders (
    id UInt64,
    total Decimal(10,2),
    user_id UInt32,
    user_name String,      -- Denormalized!
    user_country String    -- Denormalized!
) ENGINE = MergeTree()
ORDER BY (user_country, id);

-- No JOIN needed
SELECT id, total, user_name FROM orders;
```

**When you must JOIN:**
- Use Dictionaries for dimension lookups
- Put smaller table on the RIGHT side
- Consider `JOIN` engine tables

## 4. Choose the Right MergeTree Engine

| Engine | When to Use |
|--------|-------------|
| `MergeTree` | Default choice, no special requirements |
| `ReplicatedMergeTree` | Need replication (this cluster!) |
| `ReplacingMergeTree` | Need "upsert" behavior |
| `SummingMergeTree` | Auto-sum metrics on merge |
| `AggregatingMergeTree` | Pre-aggregate with state functions |
| `CollapsingMergeTree` | Track state changes with +1/-1 |
| `VersionedCollapsingMergeTree` | Same, with version ordering |

### ReplacingMergeTree Example

```sql
-- "Update" pattern: insert new row, old gets replaced on merge
CREATE TABLE users (
    id UInt32,
    name String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY id;

-- Insert initial row
INSERT INTO users VALUES (1, 'Alice', now());

-- "Update" by inserting new row with same id
INSERT INTO users VALUES (1, 'Alice Smith', now());

-- Both rows exist until merge! Use FINAL to get latest:
SELECT * FROM users FINAL WHERE id = 1;
```

## 5. Use Materialized Views for Aggregations

Pre-compute expensive aggregations:

```sql
-- Source table: raw events
CREATE TABLE events (
    timestamp DateTime,
    user_id UInt32,
    event_type String
) ENGINE = MergeTree()
ORDER BY (timestamp, user_id);

-- Aggregation table: counts per hour
CREATE TABLE events_hourly (
    hour DateTime,
    event_type String,
    count UInt64
) ENGINE = SummingMergeTree()
ORDER BY (hour, event_type);

-- Materialized view: auto-populates events_hourly
CREATE MATERIALIZED VIEW events_hourly_mv
TO events_hourly AS
SELECT
    toStartOfHour(timestamp) as hour,
    event_type,
    count() as count
FROM events
GROUP BY hour, event_type;

-- Now INSERTs to events automatically update events_hourly
INSERT INTO events VALUES (now(), 1, 'click');

-- Query the pre-aggregated table (fast!)
SELECT * FROM events_hourly;
```

## 6. Partition Wisely

```sql
CREATE TABLE events (
    timestamp DateTime,
    data String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)  -- Monthly partitions
ORDER BY timestamp;
```

**Benefits:**
- Drop old data instantly: `ALTER TABLE events DROP PARTITION 202301`
- Query only relevant partitions
- Parallel processing per partition

**Guidelines:**
- 100-1000 partitions is ideal
- Don't over-partition (millions = bad)
- Common patterns: `toYYYYMM(date)`, `toMonday(date)`

## 7. Use TTL for Data Lifecycle

Auto-delete or move old data:

```sql
CREATE TABLE logs (
    timestamp DateTime,
    message String
) ENGINE = MergeTree()
ORDER BY timestamp
TTL timestamp + INTERVAL 30 DAY;  -- Auto-delete after 30 days

-- Or move to cold storage
TTL timestamp + INTERVAL 7 DAY TO VOLUME 'cold',
    timestamp + INTERVAL 30 DAY DELETE;
```

## 8. Avoid These Anti-Patterns

| Anti-Pattern | Why It's Bad | Alternative |
|--------------|--------------|-------------|
| Single-row INSERTs | Creates tiny parts | Batch 1000+ rows |
| Frequent UPDATEs | Expensive mutations | ReplacingMergeTree |
| `SELECT *` | Reads all columns | Select only needed columns |
| High-cardinality ORDER BY first | Poor index efficiency | Low-cardinality first |
| Too many partitions | Overhead, slow startup | ~100-1000 partitions |
| JOINs on large tables | Memory pressure | Denormalize or use dictionaries |
| `Nullable` everywhere | Storage + performance overhead | Use defaults instead |

## 9. Useful System Tables

```sql
-- Table sizes and row counts
SELECT
    table,
    formatReadableSize(sum(bytes)) as size,
    sum(rows) as rows
FROM system.parts
WHERE active
GROUP BY table;

-- Running queries
SELECT * FROM system.processes;

-- Query log (recent queries)
SELECT * FROM system.query_log ORDER BY event_time DESC LIMIT 10;

-- Mutations (UPDATE/DELETE progress)
SELECT * FROM system.mutations WHERE NOT is_done;

-- Parts info
SELECT * FROM system.parts WHERE table = 'events';
```

## 10. Performance Tuning Checklist

- [ ] Batch inserts (1000+ rows)
- [ ] ORDER BY matches query patterns
- [ ] Low-cardinality columns first in ORDER BY
- [ ] Using appropriate MergeTree engine
- [ ] Denormalized where possible
- [ ] Materialized views for common aggregations
- [ ] Partitioning by time (if applicable)
- [ ] TTL for data retention
- [ ] Avoiding Nullable unless necessary
- [ ] Selecting only needed columns
