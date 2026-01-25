# ClickHouse Table Engines Guide

A guide for choosing the right table engine for your use case. Coming from traditional databases, understanding table engines is key to getting the most out of ClickHouse.

## What Are Table Engines?

In ClickHouse, the **table engine** determines:
- How and where data is stored
- Which queries are supported
- Whether data is replicated
- How concurrent access works
- Whether indexes are used

Think of engines as storage strategies. Unlike MySQL where most tables use InnoDB, ClickHouse offers specialized engines optimized for different workloads.

```sql
CREATE TABLE example (
    id UInt32,
    data String
) ENGINE = MergeTree()  -- ← The engine choice
ORDER BY id;
```

---

## Engine Families Overview

| Family | Use Case | Examples |
|--------|----------|----------|
| **MergeTree** | Production workloads, large datasets | MergeTree, ReplacingMergeTree, SummingMergeTree |
| **Log** | Small tables, temporary data | TinyLog, Log, StripeLog |
| **Integration** | External data sources | Kafka, MySQL, PostgreSQL, S3 |
| **Special** | Specific use cases | Memory, Distributed, Merge, Dictionary |

---

## MergeTree Family (Production Engines)

The MergeTree family is designed for high-performance OLAP workloads. All variants share the LSM-tree architecture (see [Database Fundamentals](database-fundamentals.md)).

### MergeTree (Standard)

The default choice for most production tables. Optimized for insert-heavy, read-heavy analytical workloads.

```sql
CREATE TABLE events (
    event_time DateTime,
    user_id UInt32,
    event_type String,
    page_url String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id);
```

**Best for:**
- Time-series data (logs, events, metrics)
- Append-heavy workloads
- Large tables (billions of rows)
- When you rarely update/delete data

**Key features:**
- Efficient range queries on ORDER BY columns
- Background data merging and compaction
- Partition pruning for faster queries
- Data compression

**When NOT to use:**
- Frequent updates to existing rows (use ReplacingMergeTree)
- Need ACID transactions (ClickHouse is not OLTP)

---

### ReplacingMergeTree

Automatically deduplicates rows with the same sorting key during background merges.

```sql
CREATE TABLE user_profiles (
    user_id UInt32,
    name String,
    email String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)  -- Keeps row with max updated_at
ORDER BY user_id;

-- Insert multiple versions
INSERT INTO user_profiles VALUES (1, 'Alice', 'alice@old.com', '2024-01-01');
INSERT INTO user_profiles VALUES (1, 'Alice', 'alice@new.com', '2024-01-15');

-- Query might show both until merge happens
SELECT * FROM user_profiles WHERE user_id = 1;

-- Force deduplication (use in queries)
SELECT * FROM user_profiles FINAL WHERE user_id = 1;  -- Only latest row
```

**Best for:**
- Changelog tables (keep latest version)
- Slowly changing dimensions
- Idempotent inserts (prevent duplicates)

**Important caveats:**
- Deduplication is **not immediate** - happens during merges
- Use `FINAL` in queries for guaranteed deduplication (slower)
- Multiple data parts may contain duplicates until merged

**Comparison to traditional databases:**

| MySQL/PostgreSQL | ClickHouse ReplacingMergeTree |
|------------------|-------------------------------|
| `UPDATE users SET email = 'new' WHERE id = 1` | Insert new row, old removed during merge |
| Immediate update | Eventually consistent |
| Row-level locking | No locking (append-only) |

---

### SummingMergeTree

Pre-aggregates numeric columns during merges. Instead of storing raw rows, sums them up.

```sql
CREATE TABLE page_views_sum (
    date Date,
    page_url String,
    views UInt64,
    clicks UInt64
) ENGINE = SummingMergeTree()
ORDER BY (date, page_url);

-- Insert raw events
INSERT INTO page_views_sum VALUES ('2024-01-01', '/home', 100, 10);
INSERT INTO page_views_sum VALUES ('2024-01-01', '/home', 50, 5);
INSERT INTO page_views_sum VALUES ('2024-01-01', '/about', 30, 3);

-- After merge, data is automatically summed
SELECT * FROM page_views_sum FINAL;
-- Result:
-- ('2024-01-01', '/home', 150, 15)   ← views and clicks summed!
-- ('2024-01-01', '/about', 30, 3)

-- Queries work as expected
SELECT page_url, sum(views) AS total_views
FROM page_views_sum
WHERE date = '2024-01-01'
GROUP BY page_url;
```

**Best for:**
- Pre-aggregated metrics (counters, sums)
- Reducing storage for aggregated data
- Time-series aggregations

**How it works:**
- Rows with same ORDER BY key are merged
- Numeric columns are summed
- Non-numeric columns: first value is kept

**When NOT to use:**
- Need raw, unaggregated data
- Want to compute AVG/COUNT (only SUM works)

---

### AggregatingMergeTree

Stores intermediate aggregation states, not final values. Most advanced MergeTree variant.

```sql
-- Create table storing aggregation states
CREATE TABLE page_stats_agg (
    date Date,
    page_url String,
    views_state AggregateFunction(sum, UInt64),
    unique_users_state AggregateFunction(uniq, UInt32)
) ENGINE = AggregatingMergeTree()
ORDER BY (date, page_url);

-- Insert using -State functions
INSERT INTO page_stats_agg
SELECT
    toDate(event_time) AS date,
    page_url,
    sumState(1) AS views_state,               -- Store sum state
    uniqState(user_id) AS unique_users_state  -- Store uniq state
FROM events
WHERE event_time >= '2024-01-01'
GROUP BY date, page_url;

-- Query using -Merge functions
SELECT
    page_url,
    sumMerge(views_state) AS total_views,           -- Merge sum states
    uniqMerge(unique_users_state) AS unique_users   -- Merge uniq states
FROM page_stats_agg
WHERE date = '2024-01-01'
GROUP BY page_url;
```

**Best for:**
- Pre-computed aggregations with complex functions (uniq, quantile)
- Materialized views
- Incremental aggregation updates

**Comparison:**

| Engine | Stores | Query |
|--------|--------|-------|
| **MergeTree** | Raw rows | `SELECT count(), uniq(user_id)` - full scan |
| **SummingMergeTree** | Summed values | `SELECT sum(views)` - fast, but only SUM |
| **AggregatingMergeTree** | Aggregation states | `SELECT sumMerge(state), uniqMerge(state)` - fast, any aggregation |

---

### CollapsingMergeTree

Models updates/deletes as pairs of rows with opposite "sign" values.

```sql
CREATE TABLE account_balances (
    account_id UInt32,
    balance Decimal(10, 2),
    sign Int8  -- 1 for insert, -1 for delete
) ENGINE = CollapsingMergeTree(sign)
ORDER BY account_id;

-- Initial balance
INSERT INTO account_balances VALUES (123, 1000.00, 1);

-- Update balance: insert old row with sign=-1, new row with sign=1
INSERT INTO account_balances VALUES
    (123, 1000.00, -1),  -- Cancel old value
    (123, 1200.00, 1);   -- New value

-- Query collapses pairs
SELECT account_id, sum(balance * sign) AS current_balance
FROM account_balances
WHERE account_id = 123
GROUP BY account_id;
-- Result: 1200.00
```

**Best for:**
- High-frequency updates (model as insert/delete pairs)
- Tracking state changes
- When update rate >> query rate

**How it works:**
- Rows with sign=1 and sign=-1 cancel each other during merges
- Effectively deletes old values

**When NOT to use:**
- Out-of-order updates (use VersionedCollapsingMergeTree)
- Simple append-only data (use MergeTree)

---

### VersionedCollapsingMergeTree

CollapsingMergeTree with version tracking to handle out-of-order inserts.

```sql
CREATE TABLE user_state (
    user_id UInt32,
    status String,
    version UInt64,  -- Timestamp or sequence number
    sign Int8
) ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY (user_id, version);

-- Insert v1
INSERT INTO user_state VALUES (1, 'active', 100, 1);

-- Update to v2 (out of order - inserted after v3)
INSERT INTO user_state VALUES
    (1, 'active', 100, -1),
    (1, 'inactive', 200, 1);

-- Update to v3 (inserted before v2)
INSERT INTO user_state VALUES
    (1, 'inactive', 200, -1),
    (1, 'active', 300, 1);

-- Query correctly handles out-of-order updates
SELECT user_id, argMax(status, version) AS current_status
FROM user_state
GROUP BY user_id;
```

**Best for:**
- Out-of-order updates
- Distributed systems with eventual consistency
- When update timestamps may arrive late

---

## Replicated Engines

All MergeTree engines have `Replicated*` variants for multi-node clusters.

```sql
-- Non-replicated (single node)
ENGINE = MergeTree()

-- Replicated (multi-node with ClickHouse Keeper/ZooKeeper)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/table_name', '{replica}')
```

**Replicated variants:**
- ReplicatedMergeTree
- ReplicatedReplacingMergeTree
- ReplicatedSummingMergeTree
- ReplicatedAggregatingMergeTree
- ReplicatedCollapsingMergeTree
- ReplicatedVersionedCollapsingMergeTree

**When to use:**
- Multi-node clusters (like the 3-node setup in this repo)
- High availability requirements
- Data redundancy

**Connection to this repo:**
```sql
-- This cluster uses ReplicatedMergeTree with macros
CREATE TABLE events ON CLUSTER default (
    event_time DateTime,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
ORDER BY event_time;
```

See [Replication & Distributed](replication-distributed.md) for details.

---

## Log Family (Small Tables)

Lightweight engines for small datasets. No indexing, no background merges.

### TinyLog

Simplest engine. Stores each column in a separate file.

```sql
CREATE TABLE countries (
    code String,
    name String
) ENGINE = TinyLog;

INSERT INTO countries VALUES ('US', 'United States'), ('UK', 'United Kingdom');
```

**Best for:**
- Small reference tables (<1M rows)
- Test data
- Temporary tables

**Limitations:**
- No concurrent reads
- No indexes
- Poor performance on large datasets

---

### Log

Like TinyLog but supports concurrent reads.

```sql
CREATE TABLE lookup_table (
    id UInt32,
    value String
) ENGINE = Log;
```

**Best for:**
- Write-once, read-many small datasets
- Lookup tables with concurrent queries

---

### StripeLog

Stores all columns in one file (more efficient for small datasets).

```sql
CREATE TABLE temp_data (
    id UInt32,
    data String
) ENGINE = StripeLog;
```

**Best for:**
- Quick inserts of small batches
- Temporary processing tables

---

## Log Family Comparison

| Engine | Concurrent Reads | Files per Column | Use Case |
|--------|------------------|------------------|----------|
| **TinyLog** | ✗ No | 1 per column | Tiny reference tables |
| **Log** | ✓ Yes | 1 per column | Small lookup tables |
| **StripeLog** | ✓ Yes | All in 1 file | Temp data, small batches |

---

## Integration Engines

Connect to external data sources.

### Kafka

Read streaming data from Kafka topics.

```sql
CREATE TABLE kafka_queue (
    user_id UInt32,
    event String,
    timestamp DateTime
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'localhost:9092',
    kafka_topic_list = 'events',
    kafka_group_name = 'clickhouse_consumer',
    kafka_format = 'JSONEachRow';

-- Typically used with materialized view to MergeTree
CREATE MATERIALIZED VIEW events_mv TO events AS
SELECT * FROM kafka_queue;
```

---

### MySQL / PostgreSQL

Query external databases directly.

```sql
CREATE TABLE mysql_users (
    id UInt32,
    name String
) ENGINE = MySQL('localhost:3306', 'database', 'users', 'user', 'password');

-- Query MySQL data from ClickHouse
SELECT * FROM mysql_users WHERE id > 100;
```

---

### URL

Read data from HTTP endpoints.

```sql
CREATE TABLE remote_data (
    id UInt32,
    data String
) ENGINE = URL('https://example.com/data.csv', 'CSV');
```

---

### S3

Read from S3 buckets.

```sql
CREATE TABLE s3_logs (
    timestamp DateTime,
    message String
) ENGINE = S3('https://bucket.s3.amazonaws.com/logs/*.csv', 'CSV');
```

---

## Special Purpose Engines

### Memory

Stores data in RAM. Data is lost on server restart.

```sql
CREATE TABLE temp_results (
    id UInt32,
    value Float64
) ENGINE = Memory;
```

**Best for:**
- Temporary query results
- Small in-memory lookup tables
- Testing

**Limitations:**
- Data lost on restart
- Limited by RAM

---

### Distributed

Virtual table that distributes queries across multiple shards.

```sql
-- On each shard, create local table
CREATE TABLE events_local (...) ENGINE = MergeTree() ...

-- Create distributed table
CREATE TABLE events_distributed AS events_local
ENGINE = Distributed(cluster_name, database, events_local, rand());

-- Query distributed table → queries all shards
SELECT count() FROM events_distributed;
```

**Best for:**
- Querying data across multiple shards
- Horizontal scaling

See [Replication & Distributed](replication-distributed.md) for details.

---

### Merge

Virtual table reading from multiple tables with same structure.

```sql
-- Suppose you have partitioned tables
CREATE TABLE events_2024_01 (...) ENGINE = MergeTree() ...
CREATE TABLE events_2024_02 (...) ENGINE = MergeTree() ...

-- Merge engine queries all matching tables
CREATE TABLE events_all (...) ENGINE = Merge(currentDatabase(), '^events_');

-- Query reads from events_2024_01, events_2024_02, etc.
SELECT count() FROM events_all;
```

**Best for:**
- Querying across partitioned tables
- Time-based table partitions (before using PARTITION BY)

---

### Dictionary

Key-value storage with caching for fast lookups.

```sql
-- Create dictionary from a table
CREATE DICTIONARY country_dict (
    code String,
    name String
) PRIMARY KEY code
SOURCE(CLICKHOUSE(TABLE 'countries'))
LAYOUT(FLAT())
LIFETIME(300);  -- Cache for 5 minutes

-- Fast lookups
SELECT dictGet('country_dict', 'name', 'US') AS country;
-- Result: 'United States'
```

**Best for:**
- Enriching data with lookups
- Replacing JOINs with small dimension tables
- Fast key-value access

---

## Choosing the Right Engine

```
                    Start Here
                        │
                        ▼
            ┌─────────────────────────┐
            │  What's your use case?  │
            └─────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
    ┌─────────┐   ┌──────────┐   ┌─────────────┐
    │ Large   │   │ External │   │ Small/Temp  │
    │ Dataset │   │ Data     │   │ Table       │
    └─────────┘   └──────────┘   └─────────────┘
        │               │               │
        │               │               ▼
        │               │         ┌──────────┐
        │               │         │ TinyLog  │
        │               │         │ Log      │
        │               │         └──────────┘
        │               │
        │               ▼
        │         ┌──────────────┐
        │         │ Kafka        │
        │         │ MySQL/PG     │
        │         │ S3/URL       │
        │         └──────────────┘
        │
        ▼
    ┌─────────────────────────────┐
    │ Need updates/deduplication? │
    └─────────────────────────────┘
        │
        ├─── No ──────────────────► MergeTree
        │
        ├─── Deduplicate ─────────► ReplacingMergeTree
        │
        ├─── Pre-aggregate sums ──► SummingMergeTree
        │
        ├─── Pre-aggregate complex ► AggregatingMergeTree
        │
        └─── Frequent updates ────► CollapsingMergeTree
                                     VersionedCollapsingMergeTree
```

---

## Quick Reference Table

| Use Case | Recommended Engine | Alternative |
|----------|-------------------|-------------|
| Time-series logs/events | MergeTree | - |
| User profiles (latest version) | ReplacingMergeTree | MergeTree + FINAL |
| Pre-aggregated metrics | SummingMergeTree | AggregatingMergeTree |
| Materialized views | AggregatingMergeTree | SummingMergeTree |
| High-frequency updates | CollapsingMergeTree | VersionedCollapsingMergeTree |
| Small lookup table (<100K rows) | TinyLog, Log | Memory |
| Temporary results | Memory | Log |
| Multi-node cluster | Replicated* variants | - |
| Query across shards | Distributed | - |
| Stream from Kafka | Kafka → MergeTree MV | - |
| Read from S3 | S3 | URL |
| Fast key-value lookups | Dictionary | JOIN |

---

## Practical Examples

### Example 1: Migrating from MergeTree to ReplacingMergeTree

```sql
-- Original table with duplicates
CREATE TABLE users_old (
    user_id UInt32,
    name String,
    email String,
    updated_at DateTime
) ENGINE = MergeTree()
ORDER BY user_id;

-- New table with deduplication
CREATE TABLE users_new (
    user_id UInt32,
    name String,
    email String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY user_id;

-- Migrate data
INSERT INTO users_new SELECT * FROM users_old;

-- Rename tables
RENAME TABLE users_old TO users_backup, users_new TO users;

-- Queries now automatically deduplicate
SELECT * FROM users FINAL WHERE user_id = 123;
```

---

### Example 2: Using SummingMergeTree for Metrics

```sql
-- Raw events table
CREATE TABLE events (
    event_time DateTime,
    metric_name String,
    value Float64
) ENGINE = MergeTree()
ORDER BY (event_time, metric_name);

-- Pre-aggregated hourly metrics
CREATE TABLE metrics_hourly (
    hour DateTime,
    metric_name String,
    total_value Float64
) ENGINE = SummingMergeTree()
ORDER BY (hour, metric_name);

-- Materialized view for automatic aggregation
CREATE MATERIALIZED VIEW metrics_hourly_mv TO metrics_hourly AS
SELECT
    toStartOfHour(event_time) AS hour,
    metric_name,
    sum(value) AS total_value
FROM events
GROUP BY hour, metric_name;

-- Query pre-aggregated data (much faster)
SELECT metric_name, sum(total_value)
FROM metrics_hourly
WHERE hour >= '2024-01-01'
GROUP BY metric_name;
```

---

### Example 3: Dictionary for Fast Lookups

```sql
-- Dimension table
CREATE TABLE products (
    product_id UInt32,
    product_name String,
    category String
) ENGINE = MergeTree()
ORDER BY product_id;

-- Create dictionary
CREATE DICTIONARY product_dict (
    product_id UInt32,
    product_name String,
    category String
) PRIMARY KEY product_id
SOURCE(CLICKHOUSE(TABLE 'products'))
LAYOUT(HASHED())
LIFETIME(3600);

-- Fast enrichment without JOIN
SELECT
    order_id,
    product_id,
    dictGet('product_dict', 'product_name', product_id) AS product_name,
    dictGet('product_dict', 'category', product_id) AS category
FROM orders
WHERE order_date = today();
```

---

## Key Takeaways

| Concept | Recommendation |
|---------|----------------|
| **Default choice** | MergeTree (handles 90% of use cases) |
| **Need deduplication** | ReplacingMergeTree (but understand merge behavior) |
| **Pre-aggregation** | SummingMergeTree (simple sums) or AggregatingMergeTree (complex) |
| **Frequent updates** | Model as insert pairs with CollapsingMergeTree |
| **Small tables** | TinyLog, Log (not MergeTree overhead) |
| **Multi-node** | Always use Replicated* variants |
| **External data** | Integration engines (Kafka, S3, MySQL) |

**Remember:**
- Choose engine based on access patterns, not just data size
- Most production tables use MergeTree or Replicated variants
- Specialized engines (Replacing, Summing, Collapsing) have specific behaviors - understand them before using
- When in doubt, start with MergeTree

---

## Next Steps

- [Database Fundamentals](database-fundamentals.md) - Understand MergeTree internals
- [Best Practices](best-practices.md) - Optimize table design and queries
- [Replication & Distributed](replication-distributed.md) - Multi-node setups
