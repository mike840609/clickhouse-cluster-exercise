# ClickHouse Basics

A quick guide for developers coming from traditional databases (MySQL, PostgreSQL).

## ClickHouse vs Traditional Databases

| Aspect | Traditional DB (MySQL/PostgreSQL) | ClickHouse |
|--------|-----------------------------------|------------|
| **Storage** | Row-oriented | Column-oriented |
| **Workload** | OLTP (transactions) | OLAP (analytics) |
| **Best for** | CRUD operations, small queries | Aggregations, large scans |
| **Write pattern** | Single row inserts | Batch inserts (1000+ rows) |
| **UPDATE/DELETE** | Fast, frequent | Expensive, async |
| **Transactions** | ACID compliant | No transactions |
| **Joins** | Optimized, common | Expensive, avoid |
| **Typical query** | `SELECT * FROM users WHERE id = 1` | `SELECT count(*), avg(price) FROM events WHERE date > '2024-01-01'` |

## Column-Oriented Storage

**Row-oriented (MySQL):**
```
Row 1: [id=1, name="Alice", age=30, city="NYC"]
Row 2: [id=2, name="Bob",   age=25, city="LA"]
Row 3: [id=3, name="Carol", age=35, city="NYC"]
```

**Column-oriented (ClickHouse):**
```
id column:   [1, 2, 3]
name column: ["Alice", "Bob", "Carol"]
age column:  [30, 25, 35]
city column: ["NYC", "LA", "NYC"]
```

**Why this matters:**
- Query `SELECT avg(age) FROM users` only reads the `age` column
- Better compression (similar values stored together)
- Vectorized processing (CPU SIMD operations)

## When to Use ClickHouse

**Good fit:**
- Analytics dashboards
- Log and event storage
- Time-series data
- Real-time reporting
- Data warehousing
- Metrics and monitoring

**Bad fit:**
- User-facing CRUD applications
- Frequent single-row updates
- Transaction-heavy workloads
- Small datasets (< 1M rows)
- Key-value lookups

## Core Concepts

### MergeTree Engine Family

The foundation of ClickHouse tables:

```sql
CREATE TABLE events (
    id UInt64,
    event_type String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (timestamp, id);
```

| Engine | Use Case |
|--------|----------|
| `MergeTree` | Basic table, no replication |
| `ReplicatedMergeTree` | Replicated across nodes |
| `ReplacingMergeTree` | Deduplicate rows by key |
| `SummingMergeTree` | Auto-sum numeric columns |
| `AggregatingMergeTree` | Store pre-aggregated data |

### ORDER BY = Physical Sort Order

Unlike traditional DBs, `ORDER BY` in table definition determines:
- How data is physically stored on disk
- Primary index structure
- Query performance

```sql
-- Good: Queries filter by timestamp first
ORDER BY (timestamp, user_id)

-- Query runs fast:
SELECT * FROM events WHERE timestamp > '2024-01-01'

-- Query runs slower (can't use index efficiently):
SELECT * FROM events WHERE user_id = 123
```

### Partitioning

Split data into separate physical parts:

```sql
CREATE TABLE events (
    id UInt64,
    timestamp DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)  -- Monthly partitions
ORDER BY (timestamp, id);
```

Benefits:
- Drop old data instantly: `ALTER TABLE events DROP PARTITION 202301`
- Query pruning: Only scan relevant partitions

## Quick Comparison Examples

### MySQL vs ClickHouse

**Finding a user (MySQL wins):**
```sql
-- MySQL: Fast (indexed lookup)
SELECT * FROM users WHERE id = 12345;

-- ClickHouse: Slower (not designed for this)
SELECT * FROM users WHERE id = 12345;
```

**Analytics query (ClickHouse wins):**
```sql
-- MySQL: Slow on large tables
SELECT
    DATE(created_at) as day,
    COUNT(*) as orders,
    SUM(total) as revenue
FROM orders
WHERE created_at > '2024-01-01'
GROUP BY day;

-- ClickHouse: Fast even on billions of rows
SELECT
    toDate(created_at) as day,
    count() as orders,
    sum(total) as revenue
FROM orders
WHERE created_at > '2024-01-01'
GROUP BY day;
```
