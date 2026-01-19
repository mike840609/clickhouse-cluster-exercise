## ClickHouse Cluster

ClickHouse Cluster Setup with 1 Shard and 3 Replicas using **ClickHouse Keeper** (ZooKeeper-free).

### Architecture

- **1 Shard, 3 Replicas**: clickhouse01, clickhouse02, clickhouse03
- **Coordination**: Embedded ClickHouse Keeper (no external ZooKeeper)
- **GUI**: Tabix web client

### Quick Start

```bash
# Full setup: clear, init, and seed with mock data
./start_and_seed.sh all

# Or run individual commands:
./start_and_seed.sh init   # Start cluster and create tables
./start_and_seed.sh seed   # Insert mock data
./start_and_seed.sh clear  # Stop and remove all data
```

### Docker Commands

```bash
# Start services
docker compose up -d

# Stop services
docker compose down

# Health check
curl http://localhost:8123/ping
# Returns "Ok."
```

### Port Mappings

| Service | HTTP Port | Native Port |
|---------|-----------|-------------|
| clickhouse01 | 8123 | 9101 |
| clickhouse02 | 8124 | 9102 |
| clickhouse03 | 8125 | 9103 |
| Tabix GUI | 8080 | - |

### Access

#### ClickHouse Native GUI
Web playground: [http://localhost:8123/play](http://localhost:8123/play)
```
Account: default
Password: (empty)
```

![ClickHouse GUI](img/image.png)

#### Tabix GUI
Web interface: [http://localhost:8080](http://localhost:8080)
```
Name: dev
Host: 127.0.0.1:8123
Login: default
Password: (empty)
```

![Tabix Setup](img/image_1.png)
![Tabix Interface](img/image_2.png)

#### CLI Access

```bash
# Connect to any node
docker exec -it clickhouse01 clickhouse-client
docker exec -it clickhouse02 clickhouse-client
docker exec -it clickhouse03 clickhouse-client
```

### Creating Replicated Tables

Use macros for automatic shard/replica substitution:

```sql
CREATE TABLE example ON CLUSTER default (
    id UInt32,
    data String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/example', '{replica}')
ORDER BY id;
```

### Mock Data

After running `./start_and_seed.sh seed`, the following tables are available:

| Table | Records | Description |
|-------|---------|-------------|
| users | 5 | User accounts |
| products | 10 | Product catalog |
| events | 15 | User activity events |

### Verify Replication

```sql
-- Check Keeper status
SELECT * FROM system.keeper_raft_state;

-- Verify data on all replicas
SELECT hostName(), count() FROM events;
```
