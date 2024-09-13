#!/bin/bash

# Function to install MongoDB tools if not installed
install_mongodb_tools() {
    if ! command -v mongodump &> /dev/null || ! command -v mongorestore &> /dev/null; then
        echo "MongoDB tools not found. Installing..."
        wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.5.1.tgz
        tar -zxvf mongodb-database-tools-debian10-x86_64-100.5.1.tgz

        # Create the directory if it does not exist
        mkdir -p /home/azureuser/bin/

        # Move the tools to the directory
        mv mongodb-database-tools-debian10-x86_64-100.5.1/bin/* /home/azureuser/bin/
        rm -rf mongodb-database-tools-debian10-x86_64-100.5.1.tgz mongodb-database-tools-debian10-x86_64-100.5.1/
        echo "MongoDB tools installed successfully."
    else
        echo "MongoDB tools already installed."
    fi
}

# Function to upload backup to Azure Storage
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

# Function to create a container and folders if not present
create_container() {
    local storage_account=$1
    local container_name=$2
    local server_name=$3

    # Create the container if it doesn't exist
    echo "Checking if container '$container_name' exists..."
    az storage container create --name "$container_name" --account-name "$storage_account"
}

# Function to delete backups older than 7 days
delete_old_backups() {
    local storage_account=$1
    local container_name=$2
    local server_name=$3

    echo "Checking for backups older than 7 days inside server: $server_name"

    # Get the current date and time in UTC, 7 days ago
    seven_days_ago=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%MZ")

    # List blobs inside the server folder
    blobs=$(az storage blob list --container-name "$container_name" --account-name "$storage_account" --prefix "$server_name/" --query "[].{name:name, lastModified:properties.lastModified}" -o tsv)
    
    while IFS=$'\t' read -r blob_name last_modified; do
        # Convert the last modified date to UTC and compare with the 7 days ago threshold
        if [[ "$last_modified" < "$seven_days_ago" && "$blob_name" != "$server_name/" ]]; then
            az storage blob delete --container-name "$container_name" --name "$blob_name" --account-name "$storage_account"
            echo "Deleted old backup: $blob_name"
        fi
    done <<< "$blobs"

    echo "Old backup cleanup completed."
}

# Function to download backup from Azure Storage
download_from_azure() {
    local storage_account=$1
    local container_path=$2
    local backup_folder=$3
    local destination_directory=$4

    echo "Downloading backup from Azure Storage account: $storage_account, container path: $container_path"
    mkdir -p "$destination_directory"
    az storage blob download-batch --destination "$destination_directory" --source "$container_path" --pattern "$backup_folder/*" --account-name "$storage_account"

    if [ $? -eq 0 ]; then
        echo "Backup downloaded successfully to $destination_directory."
    else
        echo "Failed to download backup from Azure Storage Account."
        exit 1
    fi
}

# Function to perform mongodump and upload to Azure Storage
perform_mongodump() {
    local mongo_uri=$1
    local storage_account=$2
    local server_name=$3

    # Create a timestamped folder name
    local timestamp=$(date -u +"%Y-%m-%d-%H-%M-%S")
    local container_name="mongodbbackup"
    local backup_folder="${server_name}/${server_name}_${timestamp}"

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongodump; echo 'Local backup directory /tmp/mongodump deleted.'" EXIT
    
    echo "Starting mongodump..."
    mongodump --uri="$mongo_uri" --out="/tmp/mongodump"

    if [ $? -eq 0 ]; then
        echo "Backup created successfully at /tmp/mongodump."
        create_container "$storage_account" "$container_name" "$server_name"
        upload_to_azure "$storage_account" "$container_name/$backup_folder" "/tmp/mongodump"
        delete_old_backups "$storage_account" "$container_name" "$server_name"
    else
        echo "mongodump failed."
        exit 1
    fi
}

# Function to drop all collections in a MongoDB instance
drop_all_collections() {
    local mongo_uri=$1

    echo "Dropping all collections in the database..."

    # Use the mongo shell to drop all collections in the database
    mongo "$mongo_uri" --eval '
    var dbs = db.adminCommand("listDatabases").databases;
    dbs.forEach(function(database) {
        if (database.name !== "admin" && database.name !== "local" && database.name !== "config") {
            var currentDB = db.getSiblingDB(database.name);
            currentDB.getCollectionNames().forEach(function(collection) {
                currentDB[collection].drop();
                print("Dropped collection: " + collection + " in database: " + database.name);
            });
        }
    });
    '
}

# Function to perform mongorestore from Azure Storage
perform_mongorestore() {
    local mongo_uri=$1
    local storage_account=$2
    local server_name=$3
    local timestamp=$4

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongorestore; echo 'Local restore directory /tmp/mongorestore deleted.'" EXIT

    # Create the path based on server name and timestamp
    local container_name="mongodbbackup"
    local backup_folder="${server_name}/${server_name}_${timestamp}"

    # Download backup from Azure Storage
    echo "Downloading backup from Azure Storage..."
    download_from_azure "$storage_account" "$container_name" "$backup_folder" "/tmp/mongorestore"

    # Drop all collections before restore
    echo "Dropping all collections before restore..."
    drop_all_collections "$mongo_uri"

    # Perform the actual restore
    echo "Starting actual mongorestore..."
    mongorestore --uri="$mongo_uri" --writeConcern '{w:0}' "/tmp/mongorestore/$backup_folder"

    if [ $? -eq 0 ]; then
        echo "Data restored successfully."
    else
        echo "mongorestore failed."
        exit 1
    fi
}

# Main function
main() {
    install_mongodb_tools

    if [ "$#" -lt 4 ]; then
        echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
        echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Server_Name> <Timestamp>"
        exit 1
    fi

    local action=$1

    case $action in
        mongodump)
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
                exit 1
            fi
            perform_mongodump "$2" "$3" "$4"
            ;;
        mongorestore)
            if [ "$#" -ne 5 ]; then
                echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Server_Name> <Timestamp>"
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
