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

# Function to create a container
create_container() {
    local storage_account=$1
    local container_name=$2
    az storage container create --name "$container_name" --account-name "$storage_account"
}

# Function to upload a collection backup to Azure Storage
upload_to_azure() {
    local storage_account=$1
    local container_name=$2
    local source_directory=$3

    # Check if the source directory exists
    if [ ! -d "$source_directory" ]; then
        echo "Source directory $source_directory does not exist. Skipping upload."
        return 1
    fi

    echo "Uploading backup to Azure Storage account: $storage_account, container: $container_name"
    az storage blob upload-batch --destination "$container_name" --source "$source_directory" --account-name "$storage_account"
    if [ $? -eq 0 ]; then
        echo "Backup uploaded successfully."
    else
        echo "Failed to upload backup to Azure Storage Account."
        return 1
    fi
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

        # Perform mongodump for each collection, ensuring spaces in collection names are handled
        echo "$collections" | jq -r '.[]' | while IFS= read -r collection; do
            while true; do
                echo "Starting mongodump for collection: $collection in database: $db"

                # Check if the collection exists before proceeding
                exists=$(mongosh "$mongo_uri" --quiet --eval "db.getSiblingDB('$db').getCollection('$collection').countDocuments({})" --json)

                # Extract the document count using jq (handle MongoDB's JSON output)
                count=$(echo "$exists" | jq -r '."$numberInt" // .n')

                if [[ "$count" -eq 0 ]]; then
                    echo "Collection $collection does not exist in database $db. Skipping."
                    break
                fi

                # Use quotes to handle spaces in collection names
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

# Function to restore a collection from Azure Storage
perform_mongorestore() {
    local mongo_uri=$1
    local storage_account=$2
    local server_name=$3
    local timestamp=$4

    # Create the folder structure
    local container_name="mongodbbackup"
    local backup_folder="${server_name}/${server_name}_${timestamp}"

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongorestore; echo 'Local restore directory /tmp/mongorestore deleted.'" EXIT

    # Download the backup from Azure Storage
    echo "Downloading backup from Azure Storage..."
    mkdir -p "$destination_directory"
    az storage blob download-batch --source "$container_name/$backup_folder" --destination "/tmp/mongorestore" --account-name "$storage_account"
    
    if [ $? -ne 0 ]; then
        echo "Failed to download backup from Azure Storage. Exiting."
        exit 1
    fi

    # List the databases and collections from the downloaded backup
    databases=$(ls /tmp/mongorestore)

    # Iterate over each database
    for db in $databases; do
        echo "Restoring database: $db"
        
        collections=$(ls /tmp/mongorestore/"$db")
        
        # Restore each collection
        for collection in $collections; do
            echo "Restoring collection: $collection in database: $db"
            mongorestore --uri="$mongo_uri" --db="$db" --collection="$collection" /tmp/mongorestore/"$db"/"$collection"

            if [ $? -eq 0 ]; then
                echo "Restored collection $collection successfully."
            else
                echo "mongorestore for $collection failed."
            fi
        done
    done

    echo "All collections have been restored."
}

# Main function
main() {
    install_mongodb_tools

    if [ "$#" -lt 4 ]; then
        echo "Usage: $0 <action> <MongoDB_URI> <Storage_Account_Name> <Server_Name> [Timestamp]"
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
        mongorestore)
            if [ "$#" -ne 5 ]; then
                echo "Usage: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Server_Name> <Timestamp>"
                exit 1
            fi
            perform_mongorestore "$2" "$3" "$4" "$5"
            ;;
        *)
            echo "Invalid action specified. Use 'mongodump' or 'mongorestore'."
            exit 1
            ;;
    esac
}

main "$@"