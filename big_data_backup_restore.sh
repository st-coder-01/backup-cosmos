#!/bin/bash

# Function to install MongoDB tools if not installed
install_mongodb_tools() {
    if ! command -v mongodump &> /dev/null || ! command -v mongorestore &> /dev/null; then
        echo "MongoDB tools not found. Installing..."
        wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.8.0.tgz
        tar -zxvf mongodb-database-tools-debian10-x86_64-100.8.0.tgz

        # Create the directory if it does not exist
        mkdir -p /home/azureuser/bin/

        # Move the tools to the directory
        mv mongodb-database-tools-debian10-x86_64-100.8.0/bin/* /home/azureuser/bin/
        rm -rf mongodb-database-tools-debian10-x86_64-100.8.0.tgz mongodb-database-tools-debian10-x86_64-100.8.0/
        echo "MongoDB tools installed successfully."
    else
        echo "MongoDB tools already installed."
    fi

    # Ensure mongosh shell is installed
    if ! command -v mongosh &> /dev/null; then
        echo "MongoDB shell (mongosh) not found. Installing..."
        wget https://downloads.mongodb.com/compass/mongosh-1.8.0-linux-x64.tgz
        tar -zxvf mongosh-1.8.0-linux-x64.tgz

        # Create the directory if it does not exist
        mkdir -p /home/azureuser/bin/

        # Move the mongosh shell to the directory
        mv mongosh-1.8.0-linux-x64/bin/mongosh /home/azureuser/bin/
        rm -rf mongosh-1.8.0-linux-x64*
        echo "MongoDB shell (mongosh) installed successfully."
    else
        echo "MongoDB shell (mongosh) already installed."
    fi
}

# Function to upload a collection backup to Azure Storage
upload_to_azure() {
    local storage_account=$1
    local container_name=$2
    local source_directory=$3

    echo "Uploading backup to Azure Storage account: $storage_account, container: $container_name"
    az storage blob upload-batch --destination "$container_name" --source "$source_directory" --account-name "$storage_account"
    if [ $? -eq 0 ]; then
        echo "Backup uploaded successfully."
    else
        echo "Failed to upload backup to Azure Storage Account."
        exit 1
    fi
}

# Function to create a container
create_container() {
    local storage_account=$1
    local container_name=$2
    az storage container create --name "$container_name" --account-name "$storage_account"
}

# Function to perform mongodump for each collection
perform_mongodump() {
    local mongo_uri=$1
    local storage_account=$2
    local server_name=$3
    local retry_wait_time=10

    # Create a timestamped folder name
    local timestamp=$(date -u +"%Y-%m-%d-%H-%M-%S")
    local container_name="mongodbbackup"
    local backup_folder="${server_name}/${server_name}_${timestamp}"

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongodump; echo 'Local backup directory /tmp/mongodump deleted.'" EXIT

    # Get the list of databases using mongosh with JSON output
    databases=$(mongosh "$mongo_uri" --quiet --eval "db.adminCommand('listDatabases').databases" --json)

    # Iterate over each database
    for db in $(echo "$databases" | jq -r '.[] | .name'); do
        echo "Backing up database: $db"

        # Get the list of collections for the current database using mongosh with JSON output
        collections=$(mongosh "$mongo_uri" --quiet --eval "db.getSiblingDB('$db').getCollectionNames()" --json)

        # Perform mongodump for each collection
        for collection in $(echo "$collections" | jq -r '.[]'); do
            while true; do
                echo "Starting mongodump for collection: $collection in database: $db"
                mongodump --uri="$mongo_uri" --db="$db" --collection="$collection" --out="/tmp/mongodump"

                if [ $? -eq 0 ]; then
                    echo "Backup for $collection created successfully."
                    create_container "$storage_account" "$container_name"
                    upload_to_azure "$storage_account" "$container_name/$backup_folder" "/tmp/mongodump"
                    rm -rf /tmp/mongodump
                    break
                else
                    echo "mongodump for $collection failed. Retrying in $retry_wait_time seconds..."
                    sleep "$retry_wait_time"
                fi
            done
        done
    done

    echo "All collections have been backed up."
}

# Main function
main() {
    install_mongodb_tools

    if [ "$#" -lt 4 ]; then
        echo "Usage: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
        exit 1
    fi

    local action=$1

    case $action in
        mongodump)
            if [ "$#" -ne 4 ]; then
                echo "Usage: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
                exit 1
            fi
            perform_mongodump "$2" "$3" "$4"
            ;;
        *)
            echo "Invalid action specified. Use 'mongodump'."
            exit 1
            ;;
    esac
}

main "$@"