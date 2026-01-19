# SQL Differences from MySQL/PostgreSQL

Key differences when writing SQL for ClickHouse.

## Data Types

| MySQL/PostgreSQL | ClickHouse | Notes |
|------------------|------------|-------|
| `INT` | `Int32` | Explicit size: Int8, Int16, Int32, Int64 |
| `BIGINT` | `Int64` | |
| `INT UNSIGNED` | `UInt32` | Unsigned types: UInt8, UInt16, UInt32, UInt64 |
| `FLOAT` | `Float32` | |
| `DOUBLE` | `Float64` | |
| `DECIMAL(10,2)` | `Decimal(10,2)` | Same syntax |
| `VARCHAR(255)` | `String` | No length limit needed |
| `TEXT` | `String` | Same as VARCHAR |
| `DATETIME` | `DateTime` | Second precision |
| `TIMESTAMP` | `DateTime64(3)` | Millisecond precision |
| `DATE` | `Date` | |
| `BOOLEAN` | `UInt8` | Use 0/1, or `Bool` type |
| `JSON` | `String` | Store as string, query with JSON functions |
| `ENUM` | `Enum8`/`Enum16` | `Enum8('a'=1, 'b'=2)` |
| `NULL` | `Nullable(T)` | Must explicitly declare: `Nullable(String)` |

## No Transactions

ClickHouse has no ACID transactions:

```sql
-- MySQL: This works
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;

-- ClickHouse: No equivalent
-- Design your schema to avoid needing transactions
```

## UPDATE and DELETE

Updates and deletes are **async mutations**, not instant operations:

```sql
-- MySQL: Instant
UPDATE users SET name = 'Bob' WHERE id = 1;
DELETE FROM users WHERE id = 1;

-- ClickHouse: Async mutation (rewrites data in background)
ALTER TABLE users UPDATE name = 'Bob' WHERE id = 1;
ALTER TABLE users DELETE WHERE id = 1;

-- Check mutation progress
SELECT * FROM system.mutations WHERE table = 'users';
```

**Better alternatives:**
- Use `ReplacingMergeTree` for "updates" (insert new row, old gets merged away)
- Use `TTL` for automatic deletes
- Partition data and drop entire partitions

## Primary Key Differences

| Traditional DB | ClickHouse |
|----------------|------------|
| Enforces uniqueness | No uniqueness constraint |
| B-tree index | Sparse index |
| Can be on any column | Must match ORDER BY |
| Used for lookups | Used for range scans |

```sql
-- MySQL: id is unique, indexed for lookups
CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(255)
);

-- ClickHouse: ORDER BY defines sort + primary index
-- Duplicates ARE allowed
CREATE TABLE users (
    id UInt32,
    name String
) ENGINE = MergeTree()
ORDER BY id;

-- Insert duplicate id? No error!
INSERT INTO users VALUES (1, 'Alice');
INSERT INTO users VALUES (1, 'Bob');  -- Both rows exist
```

## JOIN Differences

ClickHouse supports JOINs but they work differently:

```sql
-- The RIGHT table is loaded into memory
SELECT *
FROM large_table AS l
JOIN small_table AS s ON l.id = s.id;
-- Put the SMALLER table on the RIGHT side of JOIN
```

**JOIN types:**
- `JOIN` / `INNER JOIN` - Standard inner join
- `LEFT JOIN` - Standard left join
- `RIGHT JOIN` - Standard right join
- `FULL JOIN` - Full outer join
- `CROSS JOIN` - Cartesian product
- `ASOF JOIN` - Join on closest match (time-series)

**Best practices:**
- Keep right-side table small (loaded into memory)
- Use `JOIN` hints: `ANY`, `ALL`, `SEMI`, `ANTI`
- Prefer dictionaries over JOINs for lookups
- Denormalize data to avoid JOINs

## Syntax Differences

### Functions

```sql
-- Date functions
MySQL:      DATE(timestamp)
ClickHouse: toDate(timestamp)

MySQL:      DATE_FORMAT(ts, '%Y-%m')
ClickHouse: formatDateTime(ts, '%Y-%m')

MySQL:      NOW()
ClickHouse: now()

-- String functions
MySQL:      CONCAT(a, b)
ClickHouse: concat(a, b)  -- or just: a || b

MySQL:      SUBSTRING(str, 1, 5)
ClickHouse: substring(str, 1, 5)

-- Aggregates
MySQL:      COUNT(*)
ClickHouse: count()       -- Parentheses optional but cleaner

MySQL:      GROUP_CONCAT(name)
ClickHouse: groupArray(name)
```

### LIMIT and OFFSET

```sql
-- Same syntax
SELECT * FROM users LIMIT 10 OFFSET 20;

-- ClickHouse also supports
SELECT * FROM users LIMIT 20, 10;  -- LIMIT offset, count
```

### INSERT Syntax

```sql
-- Standard INSERT works
INSERT INTO users (id, name) VALUES (1, 'Alice');

-- Multiple rows (preferred - batch!)
INSERT INTO users (id, name) VALUES
    (1, 'Alice'),
    (2, 'Bob'),
    (3, 'Carol');

-- INSERT from SELECT
INSERT INTO users_backup SELECT * FROM users;

-- No INSERT ... ON DUPLICATE KEY UPDATE
-- Use ReplacingMergeTree instead
```

### Conditional Expressions

```sql
-- CASE works the same
SELECT
    CASE
        WHEN age < 18 THEN 'minor'
        WHEN age < 65 THEN 'adult'
        ELSE 'senior'
    END as category
FROM users;

-- ClickHouse also has if()
SELECT if(age < 18, 'minor', 'adult') FROM users;

-- And multiIf()
SELECT multiIf(
    age < 18, 'minor',
    age < 65, 'adult',
    'senior'
) FROM users;
```

## NULL Handling

```sql
-- Columns are NOT NULL by default
CREATE TABLE users (
    id UInt32,
    name String           -- Cannot be NULL
) ENGINE = MergeTree() ORDER BY id;

-- Must explicitly allow NULL
CREATE TABLE users (
    id UInt32,
    name Nullable(String) -- Can be NULL
) ENGINE = MergeTree() ORDER BY id;
```

**Note:** `Nullable` columns have slight performance overhead. Avoid if not needed.
