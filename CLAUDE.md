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
```

## Documentation

See `docs/` for ClickHouse beginner guides on basics, SQL differences, best practices, replication, and debugging.
