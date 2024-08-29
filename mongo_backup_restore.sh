#!/bin/bash

# Default paths
DEFAULT_OUTPUT_DIR="/home/azureuser/mongodb_backups"
DEFAULT_RESTORE_DIR="/home/azureuser/mongodb_restore"

# Function to download and install MongoDB tools if not already installed
install_mongodb_tools() {
    if ! command -v mongodump &>/dev/null || ! command -v mongorestore &>/dev/null; then
        echo "MongoDB tools not found. Downloading and installing MongoDB tools..."
        wget https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.5.1.tgz -O mongodb-tools.tgz
        tar -xvzf mongodb-tools.tgz
        sudo mv mongodb-database-tools-debian10-x86_64-100.5.1/bin/* /usr/local/bin/
        rm -rf mongodb-tools.tgz mongodb-database-tools-debian10-x86_64-100.5.1
        echo "MongoDB tools installed successfully."
    else
        echo "MongoDB tools are already installed."
    fi
}

# Function to upload backup to Azure Storage Account
upload_to_azure() {
    local STORAGE_ACCOUNT=$1
    local CONTAINER_NAME=$2
    local BACKUP_DIR=$3

    echo "Uploading backup to Azure Storage Account..."
    az storage blob upload-batch --destination "$CONTAINER_NAME" --source "$BACKUP_DIR" --account-name "$STORAGE_ACCOUNT"
    
    if [ $? -eq 0 ]; then
        echo "Backup uploaded successfully."
        echo "Deleting local backup..."
        rm -rf "$BACKUP_DIR"
        echo "Local backup deleted."
    else
        echo "Failed to upload backup to Azure Storage Account."
        exit 1
    fi
}

# Function to download backup from Azure Storage Account
download_from_azure() {
    local STORAGE_ACCOUNT=$1
    local CONTAINER_NAME=$2
    local DEST_DIR=$3

    # Ensure destination directory exists
    mkdir -p "$DEST_DIR"

    echo "Downloading backup from Azure Storage Account..."
    az storage blob download-batch --destination "$DEST_DIR" --source "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT"

    if [ $? -eq 0 ]; then
        echo "Backup downloaded successfully."
    else
        echo "Failed to download backup from Azure Storage Account."
        exit 1
    fi
}

# Function to perform mongodump
perform_mongodump() {
    local MONGO_URI=$1
    local STORAGE_ACCOUNT=$2
    local CONTAINER_NAME=$3

    # Ensure output directory exists
    mkdir -p "$DEFAULT_OUTPUT_DIR"

    echo "Running mongodump..."
    mongodump --uri="$MONGO_URI" --out="$DEFAULT_OUTPUT_DIR"

    if [ $? -eq 0 ]; then
        echo "Backup created successfully at $DEFAULT_OUTPUT_DIR."
        upload_to_azure "$STORAGE_ACCOUNT" "$CONTAINER_NAME" "$DEFAULT_OUTPUT_DIR"
    else
        echo "mongodump failed."
        exit 1
    fi
}

# Function to perform mongorestore
perform_mongorestore() {
    local MONGO_URI=$1
    local STORAGE_ACCOUNT=$2
    local CONTAINER_NAME=$3

    download_from_azure "$STORAGE_ACCOUNT" "$CONTAINER_NAME" "$DEFAULT_RESTORE_DIR"

    echo "Running mongorestore..."
    mongorestore --uri="$MONGO_URI" "$DEFAULT_RESTORE_DIR" --writeConcern '{w:0}'

    if [ $? -eq 0 ]; then
        echo "Data restored successfully from $DEFAULT_RESTORE_DIR."
    else
        echo "mongorestore failed."
        exit 1
    fi
}

# Main function
main() {
    # Ensure MongoDB tools are installed
    install_mongodb_tools

    if [ "$#" -lt 4 ]; then
        echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Container_Name>"
        echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Database_Name> <Storage_Account_Name> <Container_Name>"
        exit 1
    fi

    local action=$1

    case $action in
        mongodump)
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Container_Name>"
                exit 1
            fi
            perform_mongodump "$2" "$3" "$4"
            ;;
        mongorestore)
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Container_Name>"
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

# Run the main function
main "$@"