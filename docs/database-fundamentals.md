# Database Fundamentals: OLAP, OLTP, and Storage Engines

A foundational guide for developers new to analytical databases. Understanding these concepts will help you grasp why ClickHouse is designed the way it is.

## Why This Matters

Before diving into ClickHouse specifics, it helps to understand two fundamental questions:
1. **What kind of workload** is ClickHouse optimized for? (OLAP vs OLTP)
2. **How does it store data** to achieve high performance? (B+ Tree vs LSM Tree)

---

## OLAP vs OLTP

### What is OLTP (Online Transaction Processing)?

OLTP systems handle **many small, fast transactions** that modify individual records. Think of operations like:
- Processing a payment
- Updating a user's profile
- Recording an order

**Characteristics:**
- Row-oriented access (read/write entire rows)
- High concurrency (thousands of simultaneous users)
- ACID transactions (consistency is critical)
- Low latency for individual operations
- Data measured in gigabytes to terabytes

**Example databases:** MySQL, PostgreSQL, Oracle, SQL Server

```
OLTP Query Pattern (fetch one user):
┌─────────────────────────────────────────┐
│ id │ name  │ email         │ created   │  ← Reads entire row
├────┼───────┼───────────────┼───────────┤
│ 42 │ Alice │ alice@ex.com  │ 2024-01-15│  ← Returns 1 row
└────┴───────┴───────────────┴───────────┘
```

### What is OLAP (Online Analytical Processing)?

OLAP systems handle **complex analytical queries** that scan large amounts of data. Think of questions like:
- What's the total revenue by region this quarter?
- Which products have declining sales trends?
- How many events occurred per hour yesterday?

**Characteristics:**
- Column-oriented access (read specific columns across many rows)
- Read-heavy workloads (few writes, many reads)
- Aggregations and scans over millions/billions of rows
- Query latency in seconds is acceptable
- Data measured in terabytes to petabytes

**Example databases:** ClickHouse, Snowflake, BigQuery, Redshift

```
OLAP Query Pattern (aggregate across millions of rows):
┌─────────────────────────────────────────┐
│ id │ name  │ email         │ created   │
├────┼───────┼───────────────┼───────────┤
│  1 │  ...  │     ...       │ 2024-01-01│  ↑
│  2 │  ...  │     ...       │ 2024-01-01│  │
│  3 │  ...  │     ...       │ 2024-01-02│  │ Scans only
│... │  ...  │     ...       │    ...    │  │ 'created' column
│ 1M │  ...  │     ...       │ 2024-12-31│  ↓
└────┴───────┴───────────────┴───────────┘
         Only this column read ──────────┘
```

### Comparison Table

| Aspect | OLTP | OLAP |
|--------|------|------|
| **Primary Operation** | INSERT, UPDATE, DELETE | SELECT with aggregations |
| **Query Pattern** | Point lookups, small transactions | Full table scans, joins |
| **Data Access** | Row-oriented (entire rows) | Column-oriented (specific columns) |
| **Concurrency** | Thousands of users | Fewer concurrent queries |
| **Latency Goal** | Milliseconds | Seconds acceptable |
| **Data Volume** | GB to TB | TB to PB |
| **Transactions** | ACID required | Eventually consistent OK |
| **Typical Query** | `SELECT * FROM users WHERE id = 42` | `SELECT region, SUM(revenue) FROM sales GROUP BY region` |

### Why ClickHouse Chose OLAP

ClickHouse is purpose-built for analytical workloads:
- **Column storage**: Only reads columns needed for the query
- **Vectorized execution**: Processes data in batches, not row-by-row
- **No ACID overhead**: Trades transaction guarantees for speed
- **Compression**: Columns compress better (similar values together)

**Practical Example in ClickHouse:**

```sql
-- This query only reads 2 columns, even if the table has 50 columns
-- OLAP design makes this extremely fast
SELECT
    toDate(event_time) AS date,
    count() AS events
FROM events
WHERE event_time >= '2024-01-01'
GROUP BY date
ORDER BY date;
```

---

## B+ Tree vs Log-Structured Merge Tree (LSM Tree)

Storage engines determine how data is organized on disk. This affects read/write performance dramatically.

### What is a B+ Tree?

A B+ Tree is a self-balancing tree structure used by traditional databases (MySQL InnoDB, PostgreSQL).

```
                    B+ Tree Structure

                      ┌───────┐
                      │ 50,100│         ← Internal nodes
                      └───┬───┘           (keys for navigation)
                    ┌─────┼─────┐
                    ▼     ▼     ▼
              ┌────┐ ┌────┐ ┌────┐
              │10,30│ │60,80│ │120│      ← Internal nodes
              └──┬─┘ └──┬─┘ └──┬─┘
           ┌────┬┘   ┌──┴──┐   └┬────┐
           ▼    ▼    ▼     ▼    ▼    ▼
         ┌──┐┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐
         │10││30│ │60│ │80│ │100││120│   ← Leaf nodes (actual data)
         └──┘└──┘ └──┘ └──┘ └──┘ └──┘     Linked together →→→
```

**How it works:**
- **Reads**: Navigate from root to leaf, O(log n) - very fast for point lookups
- **Writes**: Find correct leaf, insert in-place, may trigger rebalancing
- **Updates**: In-place modification of existing data

**Strengths:**
- Fast point lookups (`WHERE id = 42`)
- Efficient range scans (`WHERE id BETWEEN 10 AND 100`)
- Good for read-heavy OLTP with moderate writes

**Weaknesses:**
- Random I/O for writes (must find and update specific location)
- Write amplification during rebalancing
- Not optimized for bulk inserts

### What is a Log-Structured Merge Tree (LSM Tree)?

LSM Trees are designed for high write throughput. Used by ClickHouse (MergeTree), Cassandra, RocksDB, LevelDB.

```
                    LSM Tree Structure

   ┌─────────────────────────────────────────────────────┐
   │                    Memory                           │
   │  ┌──────────────────────────────────┐              │
   │  │     MemTable (sorted in RAM)      │ ← Writes go │
   │  │  [k1:v1, k2:v2, k3:v3, ...]      │   here first │
   │  └──────────────────────────────────┘              │
   └─────────────────────────────────────────────────────┘
                         │ Flush when full
                         ▼
   ┌─────────────────────────────────────────────────────┐
   │                     Disk                            │
   │                                                     │
   │  Level 0: ┌────┐ ┌────┐ ┌────┐                     │
   │           │SST1│ │SST2│ │SST3│  ← Small, recent    │
   │           └────┘ └────┘ └────┘    files            │
   │                    │ Compaction                     │
   │                    ▼                                │
   │  Level 1: ┌─────────────────────┐                  │
   │           │    Larger SSTable   │  ← Merged files  │
   │           └─────────────────────┘                  │
   │                    │ Compaction                     │
   │                    ▼                                │
   │  Level 2: ┌──────────────────────────────┐         │
   │           │     Even Larger SSTable       │         │
   │           └──────────────────────────────┘         │
   └─────────────────────────────────────────────────────┘
```

**How it works:**
- **Writes**: Append to in-memory buffer (MemTable), then flush to disk as immutable SSTable
- **Background compaction**: Merge smaller files into larger ones, removing duplicates
- **Reads**: Check MemTable first, then search SSTables (use bloom filters to skip)

**Strengths:**
- Extremely high write throughput (sequential I/O only)
- Efficient for bulk inserts and time-series data
- Good compression (immutable, sorted files)

**Weaknesses:**
- Read amplification (may check multiple levels)
- Space amplification (data exists in multiple places until compacted)
- Background compaction uses resources

### Understanding SSTables (Sorted String Tables)

SSTable stands for **Sorted String Table** - an immutable file format that stores key-value pairs in sorted order. Understanding SSTables is crucial because they're the fundamental building block of LSM Trees.

```
                    SSTable Internal Structure

┌─────────────────────────────────────────────────────────────────┐
│                         SSTable File                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Data Blocks                           │   │
│  │  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐  │   │
│  │  │ Block 0       │ │ Block 1       │ │ Block 2       │  │   │
│  │  │ k1:v1         │ │ k100:v100     │ │ k200:v200     │  │   │
│  │  │ k2:v2         │ │ k101:v101     │ │ k201:v201     │  │   │
│  │  │ ...           │ │ ...           │ │ ...           │  │   │
│  │  │ k99:v99       │ │ k199:v199     │ │ k299:v299     │  │   │
│  │  └───────────────┘ └───────────────┘ └───────────────┘  │   │
│  │         ↑ Sorted by key within and across blocks        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Index Block                           │   │
│  │  Block 0 → offset 0      (first key: k1)                │   │
│  │  Block 1 → offset 4096   (first key: k100)              │   │
│  │  Block 2 → offset 8192   (first key: k200)              │   │
│  │         ↑ Sparse index - points to block starts         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Bloom Filter                          │   │
│  │  Probabilistic structure: "Is key X possibly here?"     │   │
│  │  - NO  → Key definitely not in this SSTable (skip it!)  │   │
│  │  - YES → Key might be here (need to check)              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Metadata/Footer                       │   │
│  │  - Index block offset                                    │   │
│  │  - Bloom filter offset                                   │   │
│  │  - Compression info, checksums                           │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Key Properties of SSTables:**

| Property | Description |
|----------|-------------|
| **Immutable** | Once written, never modified - only deleted during compaction |
| **Sorted** | Keys are in sorted order, enabling binary search and efficient merging |
| **Indexed** | Sparse index allows jumping to approximate location |
| **Filtered** | Bloom filters avoid unnecessary disk reads |

**Why Immutability Matters:**
- No locking needed for reads (multiple readers, no writers)
- Simplified crash recovery (file is complete or doesn't exist)
- Easy to cache and compress
- Compaction creates new files, deletes old ones atomically

### Comparison Table

| Aspect | B+ Tree | LSM Tree |
|--------|---------|----------|
| **Write Pattern** | Random I/O (in-place updates) | Sequential I/O (append-only) |
| **Write Speed** | Moderate | Very fast |
| **Read Speed** | Fast (single location) | Good (may check multiple levels) |
| **Point Lookups** | Excellent | Good (with bloom filters) |
| **Range Scans** | Excellent | Excellent |
| **Space Usage** | Efficient | May have temporary bloat |
| **Best For** | OLTP, mixed workloads | Write-heavy, analytics, time-series |
| **Update Strategy** | In-place | Append new version, compact later |

### Why ClickHouse Uses MergeTree

ClickHouse's MergeTree engine family is inspired by LSM Trees:

```sql
-- When you create a table like this:
CREATE TABLE events (
    event_time DateTime,
    user_id UInt32,
    event_type String
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);
```

**What happens internally:**

1. **Inserts** go to an in-memory buffer
2. **Data parts** are written to disk as immutable, sorted files
3. **Background merges** combine small parts into larger ones
4. **Column storage** keeps each column in separate files for efficient scanning

**See it in action:**

```sql
-- View the data parts (similar to SSTables)
SELECT
    name,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE table = 'events' AND active
ORDER BY modification_time DESC;
```

```
┌─name─────────────┬───rows─┬─bytes_on_disk─┬─modification_time───┐
│ 20240125_1_1_0   │  50000 │       1234567 │ 2024-01-25 10:00:00 │
│ 20240125_2_2_0   │  30000 │        789012 │ 2024-01-25 10:05:00 │
│ 20240125_1_2_1   │  80000 │       1900000 │ 2024-01-25 10:10:00 │ ← Merged!
└──────────────────┴────────┴───────────────┴─────────────────────┘
```

---

## Understanding ORDER BY in MergeTree

The `ORDER BY` clause in MergeTree is one of the most important design decisions you'll make. Unlike traditional databases where ORDER BY only affects query output, in ClickHouse it defines **how data is physically stored on disk**.

### ORDER BY vs PRIMARY KEY

```sql
-- Most common: ORDER BY and PRIMARY KEY are the same
CREATE TABLE events (
    event_time DateTime,
    user_id UInt32,
    event_type String
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);  -- PRIMARY KEY defaults to this

-- Advanced: PRIMARY KEY can be a prefix of ORDER BY
CREATE TABLE events (
    event_time DateTime,
    user_id UInt32,
    event_type String,
    session_id String
) ENGINE = MergeTree()
ORDER BY (event_time, user_id, session_id)
PRIMARY KEY (event_time, user_id);  -- Only first 2 columns indexed
```

| Clause | Purpose |
|--------|---------|
| **ORDER BY** | Defines physical sort order of data on disk |
| **PRIMARY KEY** | Defines which columns are in the sparse index (defaults to ORDER BY) |

**Why would you use a different PRIMARY KEY?**
- Save memory: Sparse index stays in RAM
- If you need data sorted by `(a, b, c)` but only query by `(a, b)`, index just `(a, b)`

### The Sparse Index (Primary Index)

ClickHouse does NOT index every row like a B+ Tree. Instead, it uses a **sparse index** that points to groups of rows called **granules**.

```
                    Sparse Index Structure

   Primary Index (in RAM)              Data on Disk (sorted by ORDER BY)
   ┌─────────────────────┐
   │ Mark 0: 2024-01-01  │ ────────►  ┌─────────────────────────────────┐
   │                     │            │ Granule 0 (rows 0-8191)         │
   │                     │            │ 2024-01-01 00:00:00, user_1     │
   │                     │            │ 2024-01-01 00:00:01, user_2     │
   │                     │            │ ...                              │
   │                     │            │ 2024-01-01 00:05:00, user_8191  │
   ├─────────────────────┤            └─────────────────────────────────┘
   │ Mark 1: 2024-01-01  │ ────────►  ┌─────────────────────────────────┐
   │         00:05:01    │            │ Granule 1 (rows 8192-16383)     │
   │                     │            │ 2024-01-01 00:05:01, user_8192  │
   │                     │            │ ...                              │
   ├─────────────────────┤            └─────────────────────────────────┘
   │ Mark 2: 2024-01-01  │ ────────►  ┌─────────────────────────────────┐
   │         00:10:15    │            │ Granule 2 (rows 16384-24575)    │
   │                     │            │ ...                              │
   ├─────────────────────┤            └─────────────────────────────────┘
   │ ...                 │
   └─────────────────────┘

   Default: 8192 rows per granule (index_granularity setting)
```

**Key insight:** For 1 billion rows, the sparse index has only ~122,000 entries (1B / 8192), easily fitting in RAM!

### How Queries Use the Index

```sql
-- Query filtering on ORDER BY prefix
SELECT count() FROM events
WHERE event_time >= '2024-01-15' AND event_time < '2024-01-16';
```

**What happens:**
1. Binary search sparse index for `event_time >= '2024-01-15'` → Find starting granule
2. Binary search for `event_time < '2024-01-16'` → Find ending granule
3. Read ONLY the granules in that range (skip everything else)

```
   Query: WHERE event_time = '2024-01-15'

   Sparse Index                      Granules Read
   ┌─────────────────┐
   │ 2024-01-01      │               ✗ Skip
   │ 2024-01-08      │               ✗ Skip
   │ 2024-01-14      │               ✗ Skip
   │ 2024-01-15 ◄────│───────────►   ✓ Read (might contain matches)
   │ 2024-01-15      │               ✓ Read (might contain matches)
   │ 2024-01-16      │               ✗ Skip
   │ ...             │               ✗ Skip
   └─────────────────┘

   Result: Read 2 granules (~16K rows) instead of 1 billion!
```

### Why ORDER BY Column Order Matters

The ORDER BY works like a **phone book** - you can search efficiently by prefix columns only.

```sql
ORDER BY (country, city, user_id)
```

| Query Filter | Index Usage | Performance |
|--------------|-------------|-------------|
| `WHERE country = 'US'` | ✓ Uses index | Fast - skips non-US granules |
| `WHERE country = 'US' AND city = 'NYC'` | ✓ Uses index | Fast - even more selective |
| `WHERE city = 'NYC'` | ✗ Cannot use index | Slow - must scan all granules |
| `WHERE user_id = 123` | ✗ Cannot use index | Slow - must scan all granules |

**Rule:** Put your most common filter columns FIRST in ORDER BY.

### Choosing a Good ORDER BY

**For time-series data (logs, events, metrics):**
```sql
-- Good: Time first (most queries filter by time range)
ORDER BY (event_time, user_id)

-- Even better: Date for partitioning, then time
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, user_id)
```

**For user analytics:**
```sql
-- Good: If most queries are "show me user X's events"
ORDER BY (user_id, event_time)
```

**For multi-tenant systems:**
```sql
-- Good: Tenant isolation + time filtering
ORDER BY (tenant_id, event_time)
```

### Practical Example: Index Usage

```sql
-- Create table with specific ORDER BY
CREATE TABLE page_views (
    view_time DateTime,
    user_id UInt32,
    page_url String,
    country String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(view_time)
ORDER BY (view_time, user_id);

-- Insert sample data (imagine millions of rows)

-- GOOD: Filters on ORDER BY prefix → uses sparse index
EXPLAIN indexes = 1
SELECT count() FROM page_views
WHERE view_time >= '2024-01-01' AND view_time < '2024-02-01';
-- Output shows: "Index Granules: X of Y" (X << Y means index helped!)

-- BAD: Filters on non-indexed column → full scan
EXPLAIN indexes = 1
SELECT count() FROM page_views
WHERE country = 'US';
-- Output shows: "Index Granules: Y of Y" (all granules scanned)
```

### ORDER BY and Compression

Bonus: Good ORDER BY improves compression!

```
Data sorted by (user_id, event_time):
┌──────────┬─────────────────────┐
│ user_id  │ event_time          │
├──────────┼─────────────────────┤
│ 1        │ 2024-01-01 10:00:00 │  ← Similar values
│ 1        │ 2024-01-01 10:05:00 │  ← together compress
│ 1        │ 2024-01-01 10:10:00 │  ← very well!
│ 2        │ 2024-01-01 09:00:00 │
│ 2        │ 2024-01-01 09:30:00 │
└──────────┴─────────────────────┘

vs Random order:
┌──────────┬─────────────────────┐
│ user_id  │ event_time          │
├──────────┼─────────────────────┤
│ 5        │ 2024-03-15 14:20:00 │  ← Varied values
│ 1        │ 2024-01-01 10:00:00 │  ← compress poorly
│ 99       │ 2024-02-28 08:45:00 │
└──────────┴─────────────────────┘
```

---

## Practical Examples

### Example 1: Column-Oriented Storage Benefits

```sql
-- Create a wide table with many columns
CREATE TABLE user_events (
    event_id UInt64,
    user_id UInt32,
    event_time DateTime,
    event_type String,
    page_url String,
    referrer String,
    browser String,
    os String,
    country String,
    city String,
    -- ... imagine 40 more columns
    extra_data String
) ENGINE = MergeTree()
ORDER BY (event_time, user_id);

-- This query only reads 2 columns out of 12+
-- In row-oriented DB: would read ALL columns for matching rows
-- In column-oriented DB: reads only event_time and count aggregation
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS events
FROM user_events
WHERE event_time >= today()
GROUP BY hour;
```

### Example 2: Understanding Batch Inserts (LSM Benefit)

```sql
-- BAD: Many small inserts (creates many tiny parts)
-- Each insert creates a new data part on disk
INSERT INTO events VALUES (now(), 1, 'click');
INSERT INTO events VALUES (now(), 2, 'view');
INSERT INTO events VALUES (now(), 3, 'click');
-- Result: 3 parts, requires more merging

-- GOOD: Batch insert (creates one part)
INSERT INTO events VALUES
    (now(), 1, 'click'),
    (now(), 2, 'view'),
    (now(), 3, 'click');
-- Result: 1 part, efficient storage

-- Check how many parts your table has
SELECT
    count() AS total_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE table = 'events' AND active;
```

### Example 3: See Query Optimization with EXPLAIN

```sql
-- See how ClickHouse optimizes column reads
EXPLAIN indexes = 1
SELECT
    user_id,
    count() AS cnt
FROM events
WHERE event_time >= '2024-01-01'
GROUP BY user_id
ORDER BY cnt DESC
LIMIT 10;
```

This shows:
- Which columns are actually read
- Index usage (primary key)
- How data is filtered before processing

---

## Key Takeaways

| Concept | Traditional DB (MySQL/PostgreSQL) | ClickHouse |
|---------|-----------------------------------|------------|
| **Workload** | OLTP (transactions) | OLAP (analytics) |
| **Storage** | Row-oriented | Column-oriented |
| **Index Structure** | B+ Tree | MergeTree (LSM-inspired) |
| **Write Strategy** | In-place updates | Append-only + merge |
| **Best For** | `WHERE id = ?` | `GROUP BY ... ORDER BY ... LIMIT` |

**Remember:**
- ClickHouse trades OLTP features (transactions, updates) for analytical speed
- MergeTree's append-only design means batch inserts are much faster than single inserts
- Column storage means queries touching few columns are extremely efficient

---

## Next Steps

- [ClickHouse Basics](clickhouse-basics.md) - Core concepts and data types
- [Best Practices](best-practices.md) - Performance optimization patterns
- [SQL Differences](sql-differences.md) - Coming from MySQL/PostgreSQL
