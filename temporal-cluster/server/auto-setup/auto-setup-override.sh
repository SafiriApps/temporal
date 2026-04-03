#!/bin/bash

set -eux -o pipefail

# === Auto setup defaults ===

TEMPORAL_HOME="${TEMPORAL_HOME:-/etc/temporal}"

DB="${DB:-cassandra}"
DB="$(echo "${DB}" | tr '[:upper:]' '[:lower:]')"
case "${DB}" in
    mysql)
        DB="mysql8"
        ;;
    postgresql|postgres)
        DB="postgres12"
        ;;
esac

SKIP_SCHEMA_SETUP="${SKIP_SCHEMA_SETUP:-false}"
SKIP_DB_CREATE="${SKIP_DB_CREATE:-${SKIP_POSTGRES_DB_CREATION:-false}}"
# Legacy alias retained during migration.
SKIP_POSTGRES_DB_CREATION="${SKIP_POSTGRES_DB_CREATION:-${SKIP_DB_CREATE}}"
SKIP_VISIBILITY_DB_SETUP="${SKIP_VISIBILITY_DB_SETUP:-false}"

# Cassandra
KEYSPACE="${KEYSPACE:-temporal}"
VISIBILITY_KEYSPACE="${VISIBILITY_KEYSPACE:-temporal_visibility}"

CASSANDRA_SEEDS="${CASSANDRA_SEEDS:-}"
CASSANDRA_PORT="${CASSANDRA_PORT:-9042}"
CASSANDRA_USER="${CASSANDRA_USER:-}"
CASSANDRA_PASSWORD="${CASSANDRA_PASSWORD:-}"
CASSANDRA_TLS_ENABLED="${CASSANDRA_TLS_ENABLED:-}"
CASSANDRA_CERT="${CASSANDRA_CERT:-}"
CASSANDRA_CERT_KEY="${CASSANDRA_CERT_KEY:-}"
CASSANDRA_CA="${CASSANDRA_CA:-}"
CASSANDRA_REPLICATION_FACTOR="${CASSANDRA_REPLICATION_FACTOR:-1}"

# MySQL/PostgreSQL
DBNAME="${DBNAME:-temporal}"
VISIBILITY_DBNAME="${VISIBILITY_DBNAME:-temporal_visibility}"
if [[ "${DB}" == "postgres12" || "${DB}" == "postgres12_pgx" ]]; then
    DB_PORT="${DB_PORT:-5432}"
else
    DB_PORT="${DB_PORT:-3306}"
fi
VISIBILITY_DB_PORT="${VISIBILITY_DB_PORT:-${DB_PORT}}"

MYSQL_SEEDS="${MYSQL_SEEDS:-}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_PWD="${MYSQL_PWD:-}"
MYSQL_TX_ISOLATION_COMPAT="${MYSQL_TX_ISOLATION_COMPAT:-false}"

POSTGRES_SEEDS="${POSTGRES_SEEDS:-}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PWD="${POSTGRES_PWD:-}"
VISIBILITY_POSTGRES_SEEDS="${VISIBILITY_POSTGRES_SEEDS:-${POSTGRES_SEEDS}}"
VISIBILITY_POSTGRES_USER="${VISIBILITY_POSTGRES_USER:-${POSTGRES_USER}}"
VISIBILITY_POSTGRES_PWD="${VISIBILITY_POSTGRES_PWD:-${POSTGRES_PWD}}"
if [ "${DB}" == "postgres12_pgx" ]; then
    POSTGRES_PLUGIN="${POSTGRES_PLUGIN:-postgres12_pgx}"
else
    POSTGRES_PLUGIN="${POSTGRES_PLUGIN:-postgres12}"
fi

# Elasticsearch
ENABLE_ES="${ENABLE_ES:-false}"
ES_SCHEME="${ES_SCHEME:-http}"
ES_SEEDS="${ES_SEEDS:-}"
ES_PORT="${ES_PORT:-9200}"
ES_USER="${ES_USER:-}"
ES_PWD="${ES_PWD:-}"
ES_VERSION="${ES_VERSION:-v7}"
ES_VIS_INDEX="${ES_VIS_INDEX:-temporal_visibility_v1_dev}"
ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS="${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS:-0}"

# Render-specific Server setup
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-${RENDER_SERVICE_NAME:-temporal}:${FRONTEND_GRPC_PORT:-7233}}"
TEMPORAL_CLI_ADDRESS="${TEMPORAL_CLI_ADDRESS:-${TEMPORAL_ADDRESS}}"
export TEMPORAL_ADDRESS
export TEMPORAL_CLI_ADDRESS

SKIP_DEFAULT_NAMESPACE_CREATION="${SKIP_DEFAULT_NAMESPACE_CREATION:-false}"
DEFAULT_NAMESPACE="${DEFAULT_NAMESPACE:-default}"
DEFAULT_NAMESPACE_RETENTION=${DEFAULT_NAMESPACE_RETENTION:-24h}

SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES="${SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES:-false}"

echo "Using repository Temporal auto-setup override."

# === Main database functions ===

validate_db_env() {
    case "${DB}" in
        mysql8)
            if [ -z "${MYSQL_SEEDS}" ]; then
                echo "MYSQL_SEEDS env must be set if DB is ${DB}."
                exit 1
            fi
            ;;
        postgres12|postgres12_pgx)
            if [ -z "${POSTGRES_SEEDS}" ]; then
                echo "POSTGRES_SEEDS env must be set if DB is ${DB}."
                exit 1
            fi
            ;;
        cassandra)
            if [ -z "${CASSANDRA_SEEDS}" ]; then
                echo "CASSANDRA_SEEDS env must be set if DB is ${DB}."
                exit 1
            fi
            ;;
        *)
            echo "Unsupported DB type: ${DB}."
            echo "Supported DB values: cassandra, mysql8, postgres12, postgres12_pgx"
            exit 1
            ;;
    esac
}

wait_for_cassandra() {
    # TODO (alex): Remove exports
    export CASSANDRA_USER=${CASSANDRA_USER}
    export CASSANDRA_PORT=${CASSANDRA_PORT}
    export CASSANDRA_ENABLE_TLS=${CASSANDRA_TLS_ENABLED}
    export CASSANDRA_TLS_CERT=${CASSANDRA_CERT}
    export CASSANDRA_TLS_KEY=${CASSANDRA_CERT_KEY}
    export CASSANDRA_TLS_CA=${CASSANDRA_CA}

    { export CASSANDRA_PASSWORD=${CASSANDRA_PASSWORD}; } 2> /dev/null

    until temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" validate-health; do
        echo 'Waiting for Cassandra to start up.'
        sleep 1
    done
    echo 'Cassandra started.'
}

wait_for_mysql() {
    until nc -z "${MYSQL_SEEDS%%,*}" "${DB_PORT}"; do
        echo 'Waiting for MySQL to start up.'
        sleep 1
    done

    echo 'MySQL started.'
}

wait_for_postgres() {
    until nc -z "${POSTGRES_SEEDS%%,*}" "${DB_PORT}"; do
        echo 'Waiting for PostgreSQL to startup.'
        sleep 1
    done

    echo 'PostgreSQL started.'
}

wait_for_db() {
    case "${DB}" in
        mysql8)
            wait_for_mysql
            ;;
        postgres12|postgres12_pgx)
            wait_for_postgres
            ;;
        cassandra)
            wait_for_cassandra
            ;;
        *)
            echo "Unsupported DB type: ${DB}."
            exit 1
            ;;
    esac
}

resolve_postgres_schema_dir() {
    local schema_name="$1"
    local override=""
    local base_dir="${TEMPORAL_HOME}/schema/postgresql"
    local matches=()

    if [ "${schema_name}" == "temporal" ]; then
        override="${TEMPORAL_POSTGRES_SCHEMA_DIR:-}"
    else
        override="${TEMPORAL_VISIBILITY_POSTGRES_SCHEMA_DIR:-}"
    fi

    if [ -n "${override}" ]; then
        if [ -d "${override}" ]; then
            echo "${override}"
            return 0
        fi

        echo "Configured PostgreSQL schema dir does not exist: ${override}" >&2
        return 1
    fi

    if [ -d "${base_dir}/v12/${schema_name}/versioned" ]; then
        echo "${base_dir}/v12/${schema_name}/versioned"
        return 0
    fi

    if [ -d "${base_dir}/v96/${schema_name}/versioned" ]; then
        echo "${base_dir}/v96/${schema_name}/versioned"
        return 0
    fi

    if [ ! -d "${base_dir}" ]; then
        echo "PostgreSQL schema base dir does not exist: ${base_dir}" >&2
        return 1
    fi

    shopt -s nullglob
    matches=( "${base_dir}"/v*/"${schema_name}"/versioned )
    shopt -u nullglob

    if [ "${#matches[@]}" -eq 0 ]; then
        echo "No PostgreSQL schema directories found under ${base_dir} for ${schema_name}" >&2
        return 1
    fi

    echo "${matches[0]}"
}

setup_cassandra_schema() {
    # TODO (alex): Remove exports
    export CASSANDRA_USER=${CASSANDRA_USER}
    export CASSANDRA_PORT=${CASSANDRA_PORT}
    export CASSANDRA_ENABLE_TLS=${CASSANDRA_TLS_ENABLED}
    export CASSANDRA_TLS_CERT=${CASSANDRA_CERT}
    export CASSANDRA_TLS_KEY=${CASSANDRA_CERT_KEY}
    export CASSANDRA_TLS_CA=${CASSANDRA_CA}

    { export CASSANDRA_PASSWORD=${CASSANDRA_PASSWORD}; } 2> /dev/null

    SCHEMA_DIR=${TEMPORAL_HOME}/schema/cassandra/temporal/versioned
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" create -k "${KEYSPACE}" --rf "${CASSANDRA_REPLICATION_FACTOR}"
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${KEYSPACE}" setup-schema -v 0.0
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${KEYSPACE}" update-schema -d "${SCHEMA_DIR}"

    VISIBILITY_SCHEMA_DIR=${TEMPORAL_HOME}/schema/cassandra/visibility/versioned
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" create -k "${VISIBILITY_KEYSPACE}" --rf "${CASSANDRA_REPLICATION_FACTOR}"
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${VISIBILITY_KEYSPACE}" setup-schema -v 0.0
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${VISIBILITY_KEYSPACE}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
}

setup_mysql_schema() {
    # TODO (alex): Remove exports
    { export SQL_PASSWORD=${MYSQL_PWD}; } 2> /dev/null

    if [ "${MYSQL_TX_ISOLATION_COMPAT}" == "true" ]; then
        MYSQL_CONNECT_ATTR=(--connect-attributes "tx_isolation=READ-COMMITTED")
    else
        MYSQL_CONNECT_ATTR=()
    fi

    MYSQL_VERSION_DIR=v8
    SCHEMA_DIR=${TEMPORAL_HOME}/schema/mysql/${MYSQL_VERSION_DIR}/temporal/versioned
    if [[ "${SKIP_DB_CREATE}" != true ]]; then
        temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${DBNAME}" create
    fi
    temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${DBNAME}" update-schema -d "${SCHEMA_DIR}"

    if [[ "${ENABLE_ES}" != true && "${SKIP_VISIBILITY_DB_SETUP}" != true ]]; then
        VISIBILITY_SCHEMA_DIR=${TEMPORAL_HOME}/schema/mysql/${MYSQL_VERSION_DIR}/visibility/versioned
        if [[ "${SKIP_DB_CREATE}" != true ]]; then
            temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${VISIBILITY_DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${VISIBILITY_DBNAME}" create
        fi
        temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${VISIBILITY_DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${VISIBILITY_DBNAME}" setup-schema -v 0.0
        temporal-sql-tool --plugin "${DB}" --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" -p "${VISIBILITY_DB_PORT}" "${MYSQL_CONNECT_ATTR[@]}" --db "${VISIBILITY_DBNAME}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
    fi
}

setup_postgres_schema() {
    # TODO (alex): Remove exports
    { export SQL_PASSWORD=${POSTGRES_PWD}; } 2> /dev/null

    SCHEMA_DIR=$(resolve_postgres_schema_dir temporal)
    echo "Using PostgreSQL schema dir: ${SCHEMA_DIR}"
    # Create database only if its name is different from the user name. Otherwise PostgreSQL container itself will create database.
    if [[ "${DBNAME}" != "${POSTGRES_USER}" && "${SKIP_DB_CREATE}" != true ]]; then
        temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" create --db "${DBNAME}"
    fi
    temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${DBNAME}" update-schema -d "${SCHEMA_DIR}"

    if [[ "${ENABLE_ES}" != true && "${SKIP_VISIBILITY_DB_SETUP}" != true ]]; then
        { export SQL_PASSWORD=${VISIBILITY_POSTGRES_PWD}; } 2> /dev/null
        VISIBILITY_SCHEMA_DIR=$(resolve_postgres_schema_dir visibility)
        echo "Using PostgreSQL visibility schema dir: ${VISIBILITY_SCHEMA_DIR}"
        if [[ "${VISIBILITY_DBNAME}" != "${VISIBILITY_POSTGRES_USER}" && "${SKIP_DB_CREATE}" != true ]]; then
            temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${VISIBILITY_POSTGRES_SEEDS}" -u "${VISIBILITY_POSTGRES_USER}" -p "${VISIBILITY_DB_PORT}" create --db "${VISIBILITY_DBNAME}"
        fi
        temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${VISIBILITY_POSTGRES_SEEDS}" -u "${VISIBILITY_POSTGRES_USER}" -p "${VISIBILITY_DB_PORT}" --db "${VISIBILITY_DBNAME}" setup-schema -v 0.0
        temporal-sql-tool --plugin "${POSTGRES_PLUGIN}" --ep "${VISIBILITY_POSTGRES_SEEDS}" -u "${VISIBILITY_POSTGRES_USER}" -p "${VISIBILITY_DB_PORT}" --db "${VISIBILITY_DBNAME}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
    fi
}

setup_schema() {
    case "${DB}" in
        mysql8)
            echo 'Setup MySQL schema.'
            setup_mysql_schema
            ;;
        postgres12|postgres12_pgx)
            echo 'Setup PostgreSQL schema.'
            setup_postgres_schema
            ;;
        cassandra)
            echo 'Setup Cassandra schema.'
            setup_cassandra_schema
            ;;
        *)
            echo "Unsupported DB type: ${DB}."
            exit 1
            ;;
    esac
}

# === Elasticsearch functions ===

validate_es_env() {
    if [ "${ENABLE_ES}" == true ]; then
        if [ -z "${ES_SEEDS}" ]; then
            echo "ES_SEEDS env must be set if ENABLE_ES is ${ENABLE_ES}"
            exit 1
        fi
    fi
}

wait_for_es() {
    SECONDS=0

    ES_SERVER="${ES_SCHEME}://${ES_SEEDS%%,*}:${ES_PORT}"

    until curl --silent --fail --user "${ES_USER}":"${ES_PWD}" "${ES_SERVER}" > /dev/null 2>&1; do
        DURATION=${SECONDS}

        if [ "${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS}" -gt 0 ] && [ ${DURATION} -ge "${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS}" ]; then
            echo 'WARNING: timed out waiting for Elasticsearch to start up. Skipping index creation.'
            return;
        fi

        echo 'Waiting for Elasticsearch to start up.'
        sleep 1
    done

    echo 'Elasticsearch started.'
}

setup_es_index() {
    ES_SERVER="${ES_SCHEME}://${ES_SEEDS%%,*}:${ES_PORT}"
# @@@SNIPSTART setup-es-template-commands
    # ES_SERVER is the URL of Elasticsearch server i.e. "http://localhost:9200".
    SETTINGS_URL="${ES_SERVER}/_cluster/settings"
    SETTINGS_FILE=${TEMPORAL_HOME}/schema/elasticsearch/visibility/cluster_settings_${ES_VERSION}.json
    TEMPLATE_URL="${ES_SERVER}/_template/temporal_visibility_v1_template"
    SCHEMA_FILE=${TEMPORAL_HOME}/schema/elasticsearch/visibility/index_template_${ES_VERSION}.json
    INDEX_URL="${ES_SERVER}/${ES_VIS_INDEX}"
    curl --fail --user "${ES_USER}":"${ES_PWD}" -X PUT "${SETTINGS_URL}" -H "Content-Type: application/json" --data-binary "@${SETTINGS_FILE}" --write-out "\n"
    curl --fail --user "${ES_USER}":"${ES_PWD}" -X PUT "${TEMPLATE_URL}" -H 'Content-Type: application/json' --data-binary "@${SCHEMA_FILE}" --write-out "\n"
    INDEX_STATUS=$(curl --silent --output /dev/null --write-out "%{http_code}" --user "${ES_USER}":"${ES_PWD}" "${INDEX_URL}")
    if [ "${INDEX_STATUS}" == "200" ]; then
        echo "Elasticsearch visibility index ${ES_VIS_INDEX} already exists."
    elif [ "${INDEX_STATUS}" == "404" ]; then
        curl --fail --user "${ES_USER}":"${ES_PWD}" -X PUT "${INDEX_URL}" --write-out "\n"
    else
        echo "Unexpected Elasticsearch response while checking visibility index ${ES_VIS_INDEX}: ${INDEX_STATUS}" >&2
        return 1
    fi
# @@@SNIPEND
}

# === Server setup ===

register_default_namespace() {
    echo "Registering default namespace: ${DEFAULT_NAMESPACE}."
    if ! temporal operator namespace describe --namespace "${DEFAULT_NAMESPACE}" > /dev/null 2>&1; then
        echo "Default namespace ${DEFAULT_NAMESPACE} not found. Creating..."
        temporal operator namespace create --retention "${DEFAULT_NAMESPACE_RETENTION}" --description "Default namespace for Temporal Server." --namespace "${DEFAULT_NAMESPACE}"
        echo "Default namespace ${DEFAULT_NAMESPACE} registration complete."
    else
        echo "Default namespace ${DEFAULT_NAMESPACE} already registered."
    fi
}

add_custom_search_attributes() {
      until temporal operator search-attribute list --namespace "${DEFAULT_NAMESPACE}" > /dev/null 2>&1; do
          echo "Waiting for namespace cache to refresh..."
          sleep 1
      done
      echo "Namespace cache refreshed."

      echo "Adding Custom*Field search attributes."
      # TODO: Remove CustomStringField
# @@@SNIPSTART add-custom-search-attributes-for-testing-command
      temporal operator search-attribute create --namespace "${DEFAULT_NAMESPACE}" \
          --name CustomKeywordField --type Keyword \
          --name CustomStringField --type Text \
          --name CustomTextField --type Text \
          --name CustomIntField --type Int \
          --name CustomDatetimeField --type Datetime \
          --name CustomDoubleField --type Double \
          --name CustomBoolField --type Bool
# @@@SNIPEND
}

setup_server(){
    echo "Temporal address: ${TEMPORAL_ADDRESS}."

    until temporal operator cluster health | grep -q SERVING; do
        echo "Waiting for Temporal server to start..."
        sleep 1
    done
    echo "Temporal server started."

    if [ "${SKIP_DEFAULT_NAMESPACE_CREATION}" != true ]; then
        register_default_namespace
    fi

    if [ "${SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES}" != true ]; then
        add_custom_search_attributes
    fi
}

# === Main ===

if [ "${SKIP_SCHEMA_SETUP}" != true ]; then
    validate_db_env
    wait_for_db
    setup_schema
fi

if [ "${ENABLE_ES}" == true ]; then
    validate_es_env
    wait_for_es
    setup_es_index
fi

# Run this func in parallel process. It will wait for server to start and then run required steps.
setup_server &
