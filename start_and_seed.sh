#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 {init|clear|seed|all}"
    echo ""
    echo "Commands:"
    echo "  init   - Start the cluster and create tables"
    echo "  clear  - Stop cluster and remove all data volumes"
    echo "  seed   - Insert mock data (requires running cluster)"
    echo "  all    - Run clear + init + seed"
    exit 1
}

wait_for_cluster() {
    echo -e "${YELLOW}Waiting for cluster to be ready...${NC}"
    max_attempts=30
    attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -s http://localhost:8123/ping | grep -q "Ok"; then
            echo -e "${GREEN}clickhouse01 is ready!${NC}"
            break
        fi
        echo "Waiting for clickhouse01... (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo -e "${RED}ERROR: Cluster failed to start${NC}"
        exit 1
    fi

    # Wait for Keeper quorum
    echo "Waiting for Keeper quorum to establish..."
    sleep 5

    # Verify Keeper
    if docker exec clickhouse01 clickhouse-client -q "SELECT count() FROM system.zookeeper WHERE path = '/'" > /dev/null 2>&1; then
        echo -e "${GREEN}Keeper quorum established!${NC}"
    else
        echo -e "${YELLOW}WARNING: Keeper may not be fully ready, continuing anyway...${NC}"
    fi
}

do_init() {
    echo -e "${GREEN}=== Initializing ClickHouse Cluster ===${NC}"

    docker compose up -d

    wait_for_cluster

    echo ""
    echo -e "${GREEN}=== Creating replicated tables ===${NC}"

    # Create events table
    docker exec clickhouse01 clickhouse-client -q "
    CREATE TABLE IF NOT EXISTS events ON CLUSTER default (
        id UInt64,
        event_type String,
        user_id UInt32,
        timestamp DateTime,
        data String
    ) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
    ORDER BY (timestamp, id)
    PARTITION BY toYYYYMM(timestamp);
    "
    echo "  - Table 'events' created"

    # Create users table
    docker exec clickhouse01 clickhouse-client -q "
    CREATE TABLE IF NOT EXISTS users ON CLUSTER default (
        id UInt32,
        username String,
        email String,
        created_at DateTime,
        is_active UInt8
    ) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/users', '{replica}')
    ORDER BY id;
    "
    echo "  - Table 'users' created"

    # Create products table
    docker exec clickhouse01 clickhouse-client -q "
    CREATE TABLE IF NOT EXISTS products ON CLUSTER default (
        id UInt32,
        name String,
        category String,
        price Decimal(10,2),
        stock UInt32
    ) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/products', '{replica}')
    ORDER BY id;
    "
    echo "  - Table 'products' created"

    echo ""
    echo -e "${GREEN}=== Cluster initialized! ===${NC}"
    print_access_info
}

do_clear() {
    echo -e "${RED}=== Clearing ClickHouse Cluster ===${NC}"

    echo "Stopping containers..."
    docker compose down 2>/dev/null || true

    echo "Removing data volumes..."
    docker volume rm clickhouse-cluster_clickhouse01_data 2>/dev/null || true
    docker volume rm clickhouse-cluster_clickhouse02_data 2>/dev/null || true
    docker volume rm clickhouse-cluster_clickhouse03_data 2>/dev/null || true

    echo -e "${GREEN}Cluster cleared!${NC}"
}

do_seed() {
    echo -e "${GREEN}=== Inserting mock data ===${NC}"

    # Check if cluster is running
    if ! curl -s http://localhost:8123/ping | grep -q "Ok"; then
        echo -e "${RED}ERROR: Cluster is not running. Run '$0 init' first.${NC}"
        exit 1
    fi

    # Seed users
    echo "Inserting users..."
    docker exec clickhouse01 clickhouse-client -q "
    INSERT INTO users (id, username, email, created_at, is_active) VALUES
        (1001, 'alice', 'alice@example.com', '2024-01-01 09:00:00', 1),
        (1002, 'bob', 'bob@example.com', '2024-01-02 10:00:00', 1),
        (1003, 'charlie', 'charlie@example.com', '2024-01-03 11:00:00', 1),
        (1004, 'diana', 'diana@example.com', '2024-01-04 12:00:00', 0),
        (1005, 'eve', 'eve@example.com', '2024-01-05 13:00:00', 1);
    "
    echo "  - Inserted 5 users"

    # Seed products
    echo "Inserting products..."
    docker exec clickhouse01 clickhouse-client -q "
    INSERT INTO products (id, name, category, price, stock) VALUES
        (1, 'Laptop', 'Electronics', 999.99, 50),
        (2, 'Mouse', 'Electronics', 29.99, 200),
        (3, 'Keyboard', 'Electronics', 79.99, 150),
        (4, 'Monitor', 'Electronics', 299.99, 75),
        (5, 'Headphones', 'Electronics', 149.99, 100),
        (6, 'Desk Chair', 'Furniture', 249.99, 30),
        (7, 'Standing Desk', 'Furniture', 499.99, 20),
        (8, 'Notebook', 'Office', 4.99, 500),
        (9, 'Pen Set', 'Office', 12.99, 300),
        (10, 'Backpack', 'Accessories', 59.99, 80);
    "
    echo "  - Inserted 10 products"

    # Seed events
    echo "Inserting events..."
    docker exec clickhouse01 clickhouse-client -q "
    INSERT INTO events (id, event_type, user_id, timestamp, data) VALUES
        (1, 'login', 1001, '2024-01-15 10:00:00', '{\"ip\": \"192.168.1.1\"}'),
        (2, 'page_view', 1001, '2024-01-15 10:01:00', '{\"page\": \"/home\"}'),
        (3, 'click', 1001, '2024-01-15 10:02:00', '{\"button\": \"signup\"}'),
        (4, 'login', 1002, '2024-01-15 10:05:00', '{\"ip\": \"192.168.1.2\"}'),
        (5, 'page_view', 1002, '2024-01-15 10:06:00', '{\"page\": \"/products\"}'),
        (6, 'purchase', 1002, '2024-01-15 10:10:00', '{\"product_id\": 1, \"amount\": 999.99}'),
        (7, 'logout', 1001, '2024-01-15 10:15:00', '{}'),
        (8, 'login', 1003, '2024-01-15 11:00:00', '{\"ip\": \"192.168.1.3\"}'),
        (9, 'page_view', 1003, '2024-01-15 11:01:00', '{\"page\": \"/about\"}'),
        (10, 'click', 1003, '2024-01-15 11:02:00', '{\"button\": \"contact\"}'),
        (11, 'login', 1005, '2024-01-15 12:00:00', '{\"ip\": \"192.168.1.5\"}'),
        (12, 'page_view', 1005, '2024-01-15 12:01:00', '{\"page\": \"/products\"}'),
        (13, 'purchase', 1005, '2024-01-15 12:05:00', '{\"product_id\": 2, \"amount\": 29.99}'),
        (14, 'purchase', 1005, '2024-01-15 12:06:00', '{\"product_id\": 3, \"amount\": 79.99}'),
        (15, 'logout', 1005, '2024-01-15 12:10:00', '{}');
    "
    echo "  - Inserted 15 events"

    # Wait for replication
    echo ""
    echo "Waiting for replication..."
    sleep 2

    # Verify replication
    echo ""
    echo -e "${GREEN}=== Verifying replication ===${NC}"
    echo ""
    printf "%-15s %-10s %-10s %-10s\n" "Table" "Node01" "Node02" "Node03"
    printf "%-15s %-10s %-10s %-10s\n" "-----" "------" "------" "------"

    for table in users products events; do
        count1=$(docker exec clickhouse01 clickhouse-client -q "SELECT count() FROM $table")
        count2=$(docker exec clickhouse02 clickhouse-client -q "SELECT count() FROM $table")
        count3=$(docker exec clickhouse03 clickhouse-client -q "SELECT count() FROM $table")
        printf "%-15s %-10s %-10s %-10s\n" "$table" "$count1" "$count2" "$count3"
    done

    echo ""
    echo -e "${GREEN}=== Sample queries ===${NC}"
    echo ""
    echo "Events by type:"
    docker exec clickhouse01 clickhouse-client -q "
    SELECT event_type, count() as count
    FROM events
    GROUP BY event_type
    ORDER BY count DESC
    FORMAT Pretty
    "

    echo ""
    echo "Products by category:"
    docker exec clickhouse01 clickhouse-client -q "
    SELECT category, count() as products, sum(stock) as total_stock
    FROM products
    GROUP BY category
    FORMAT Pretty
    "

    echo ""
    echo -e "${GREEN}Mock data inserted successfully!${NC}"
}

print_access_info() {
    echo ""
    echo "Access points:"
    echo "  - ClickHouse HTTP: http://localhost:8123/play"
    echo "  - Tabix GUI:       http://localhost:8080"
    echo ""
    echo "Connect via CLI:"
    echo "  docker exec -it clickhouse01 clickhouse-client"
}

# Main
case "${1:-}" in
    init)
        do_init
        ;;
    clear)
        do_clear
        ;;
    seed)
        do_seed
        ;;
    all)
        do_clear
        do_init
        do_seed
        ;;
    *)
        usage
        ;;
esac
