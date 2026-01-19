# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a ClickHouse cluster setup using Docker Compose with 1 shard and 3 replica nodes for high availability. The cluster uses ZooKeeper for coordination and includes Tabix for web-based database management.

## Architecture

### Cluster Topology
- **1 Shard** with **3 Replicas** (clickhouse01, clickhouse02, clickhouse03)
- All replicas in the same shard use `internal_replication: true`
- **ZooKeeper** handles distributed coordination for replication
- **Tabix GUI** provides web-based query interface

### Node Configuration
Each ClickHouse node has:
- `macros.xml` - Defines shard and replica identifiers, remote server cluster topology, and ZooKeeper connection
- `network.xml` - Configures HTTP/TCP ports and network access (allows connections from any host)

The replica identifier in `macros.xml` differs per node (clickhouse01/02/03) while all share the same shard number (1).

### Port Mappings
- **clickhouse01**: HTTP 8123, Native 9101 (container 9000)
- **clickhouse02**: HTTP 8124, Native 9102 (container 9000)
- **clickhouse03**: HTTP 8125, Native 9103 (container 9000)
- **ZooKeeper**: 2181
- **Tabix**: 8080

## Commands

### Cluster Management
```bash
# Start the cluster
docker compose up -d

# Stop the cluster
docker compose down

# Check cluster health
curl http://localhost:8123/ping
# Expected response: "Ok."
```

### Accessing ClickHouse

**Web Interfaces:**
- ClickHouse native GUI: http://localhost:8123/play
- Tabix GUI: http://localhost:8080

**Default Credentials:**
- Username: `default`
- Password: (empty)

**CLI Access:**
```bash
# Connect to clickhouse01
docker exec -it clickhouse01 clickhouse-client

# Connect to specific node
docker exec -it clickhouse02 clickhouse-client
docker exec -it clickhouse03 clickhouse-client
```

### Admin User Setup
The `init_admin.sql` file creates an admin user with full privileges:
```bash
# Execute on any node
docker exec -i clickhouse01 clickhouse-client < init_admin.sql
```
Admin credentials: username `admin`, password `test`

## Working with Replicated Tables

When creating replicated tables in this cluster, use the macros defined in configuration:
```sql
CREATE TABLE example_table ON CLUSTER default (
    id UInt32,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/example_table', '{replica}')
ORDER BY id;
```

The `{shard}` and `{replica}` macros are automatically substituted based on each node's `macros.xml` configuration.
