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
    local server_name=$2
    local backup_folder=$3

    echo "Uploading backup to Azure Storage account: $storage_account, server: $server_name"

    # Ensure the 'mongodbbackup' container exists
    az storage container create --name "mongodbbackup" --account-name "$storage_account"

    # Ensure the server name folder exists inside the container
    folder_exists=$(az storage blob list --container-name "mongodbbackup" --prefix "$server_name/" --account-name "$storage_account" --query "length(@)" -o tsv)
    if [ "$folder_exists" -eq 0 ]; then
        echo "Creating server folder '$server_name' inside 'mongodbbackup' container."
        az storage blob upload --container-name "mongodbbackup" --file /dev/null --name "$server_name/"
    fi

    # Upload the backup to the server folder inside the 'mongodbbackup' container
    az storage blob upload-batch --destination "mongodbbackup/$server_name" --source "$backup_folder" --account-name "$storage_account"

    if [ $? -eq 0 ]; then
        echo "Backup uploaded successfully."
    else
        echo "Failed to upload backup to Azure Storage Account."
        exit 1
    fi
}

# Function to delete backups older than 7 days
delete_old_backups() {
    local storage_account=$1
    local server_name=$2

    echo "Checking for backups older than 7 days in server folder: $server_name"

    # Get the current date and time in UTC, 7 days ago
    seven_days_ago=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S.0000000Z")

    # List all blobs in the server folder and filter by last modified date
    blobs=$(az storage blob list --container-name "mongodbbackup" --prefix "$server_name/" --account-name "$storage_account" --query "[?properties.lastModified<'$seven_days_ago'].name" -o tsv)

    # Delete each blob older than 7 days
    for blob in $blobs; do
        az storage blob delete --container-name "mongodbbackup" --name "$blob" --account-name "$storage_account"
        echo "Deleted old backup: $blob"
    done

    echo "Old backup cleanup completed."
}

# Function to download backup from Azure Storage
download_from_azure() {
    local storage_account=$1
    local server_name=$2
    local destination_directory=$3

    echo "Downloading backup from Azure Storage account: $storage_account, server: $server_name"
    mkdir -p "$destination_directory"
    az storage blob download-batch --destination "$destination_directory" --source "mongodbbackup/$server_name" --account-name "$storage_account"

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

    # Create a timestamped folder name for the backup
    local timestamp=$(date -u +"%Y-%m-%d-%H-%M-%S")
    local backup_folder="/tmp/mongodump/${server_name}_${timestamp}"

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongodump; echo 'Local backup directory /tmp/mongodump deleted.'" EXIT
    
    echo "Starting mongodump..."
    mongodump --uri="$mongo_uri" --out="$backup_folder"

    if [ $? -eq 0 ]; then
        echo "Backup created successfully at $backup_folder."
        upload_to_azure "$storage_account" "$server_name" "$backup_folder"
    else
        echo "mongodump failed."
        exit 1
    fi

    # Remove backups older than 7 days
    delete_old_backups "$storage_account" "$server_name"
}

# Function to perform mongorestore from Azure Storage
perform_mongorestore() {
    local mongo_uri=$1
    local storage_account=$2
    local server_name=$3

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongorestore; echo 'Local restore directory /tmp/mongorestore deleted.'" EXIT

    # Download backup from Azure Storage
    download_from_azure "$storage_account" "$server_name" "/tmp/mongorestore"

    echo "Starting mongorestore..."
    mongorestore --uri="$mongo_uri" "/tmp/mongorestore" --writeConcern "{w:0}"
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
        echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
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
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Server_Name>"
                exit 1
            fi
            perform_mongorestore "$2" "$3" "$4"
            ;;
        *)
            echo "Invalid action specified. Use 'mongodump' or 'mongorestore'."
            exit 1
            ;;
    esac
}

main "$@"
