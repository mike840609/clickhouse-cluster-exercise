# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

ClickHouse cluster setup using Docker Compose with 1 shard and 3 replica nodes. Uses embedded ClickHouse Keeper for coordination (ZooKeeper-free).

## Architecture

### Cluster Topology
- **1 Shard** with **3 Replicas** (clickhouse01, clickhouse02, clickhouse03)
- All replicas use `internal_replication: true`
- **ClickHouse Keeper** embedded in each node for distributed coordination
- **Tabix GUI** for web-based queries

### Node Configuration Files
Each `clickhouse0X/` directory contains:
- `macros.xml` - Shard/replica identifiers, remote servers, Keeper connection (port 9181)
- `network.xml` - HTTP/TCP ports and network access
- `keeper.xml` - Raft configuration for embedded Keeper (server IDs 1-3, port 9234)

### Port Mappings
| Service | HTTP | Native |
|---------|------|--------|
| clickhouse01 | 8123 | 9101 |
| clickhouse02 | 8124 | 9102 |
| clickhouse03 | 8125 | 9103 |
| Tabix GUI | 8080 | - |

## Commands

### Quick Start
```bash
./start_and_seed.sh all    # Clear, init, and seed with mock data
./start_and_seed.sh init   # Start cluster and create tables
./start_and_seed.sh seed   # Insert mock data
./start_and_seed.sh clear  # Stop and remove all data volumes
```

### Manual Docker Commands
```bash
docker compose up -d       # Start cluster
docker compose down        # Stop cluster
curl http://localhost:8123/ping  # Health check (returns "Ok.")
```

### CLI Access
```bash
docker exec -it clickhouse01 clickhouse-client
docker exec -it clickhouse02 clickhouse-client
docker exec -it clickhouse03 clickhouse-client
```

### Web GUI Access
**ClickHouse Play** (built-in): http://localhost:8123/play
- Account: `default`
- Password: (empty)

**Tabix GUI**: http://localhost:8080
- Name: `dev`
- Host: `127.0.0.1:8123`
- Login: `default`
- Password: (empty)

### Admin User
```bash
docker exec -i clickhouse01 clickhouse-client < init_admin.sql
```
Credentials: `admin` / `test`

## Working with Replicated Tables

Use macros for automatic shard/replica substitution:
```sql
CREATE TABLE example ON CLUSTER default (
    id UInt32,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/example', '{replica}')
ORDER BY id;
```

The `{shard}` and `{replica}` macros expand based on each node's `macros.xml`.

## Useful Queries

```sql
-- Check Keeper status
SELECT * FROM system.keeper_raft_state;

-- Check replication health
SELECT database, table, is_leader, active_replicas, queue_size FROM system.replicas;

-- Verify data across replicas
SELECT hostName(), count() FROM events;

-- View data parts (MergeTree storage)
SELECT name, rows, bytes_on_disk, modification_time
FROM system.parts
WHERE table = 'events' AND active
ORDER BY modification_time DESC;
```

## Mock Data

After running `./start_and_seed.sh seed`:

| Table | Records | Description |
|-------|---------|-------------|
| users | 5 | User accounts |
| products | 10 | Product catalog |
| events | 15 | User activity events |

## Documentation

See `docs/` for ClickHouse beginner guides:
- [Database Fundamentals](docs/database-fundamentals.md) - OLAP vs OLTP, B+ Tree vs LSM Tree, MergeTree ORDER BY
- [ClickHouse Basics](docs/clickhouse-basics.md) - Column storage, core concepts, data types
- [Table Engines](docs/clickhouse-engines.md) - MergeTree family, Log family, choosing the right engine
- [SQL Differences](docs/sql-differences.md) - Coming from MySQL/PostgreSQL
- [Best Practices](docs/best-practices.md) - Insert patterns, schema design, performance
- [Replication & Distributed](docs/replication-distributed.md) - How data replicates across nodes
- [Debugging & Troubleshooting](docs/debugging-troubleshooting.md) - EXPLAIN, system tables, common issues
