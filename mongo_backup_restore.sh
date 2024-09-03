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
    az storage container create --name "$container_name" --account-name "$storage_account"
    az storage blob upload-batch --destination "$container_name" --source "$source_directory" --account-name "$storage_account"
    if [ $? -eq 0 ]; then
        echo "Backup uploaded successfully."
    else
        echo "Failed to upload backup to Azure Storage Account."
        exit 1
    fi
}

# Function to download backup from Azure Storage
download_from_azure() {
    local storage_account=$1
    local container_name=$2
    local destination_directory=$3

    echo "Downloading backup from Azure Storage account: $storage_account, container: $container_name"
    mkdir -p "$destination_directory"
    az storage blob download-batch --destination "$destination_directory" --source "$container_name" --account-name "$storage_account"

    if [ $? -eq 0 ]; then
        echo "Backup downloaded successfully to $destination_directory."
    else
        echo "Failed to download backup from Azure Storage Account."
        exit 1
    fi
}

# Function to delete containers older than 7 days
delete_old_containers() {
    local storage_account=$1

    echo "Checking for containers older than 7 days in storage account: $storage_account"

    # Get the current date and time in UTC, 7 days ago
    seven_days_ago=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%MZ")

    # List all containers with their last modified date
    containers=$(az storage container list --account-name "$storage_account" --query "[].{name:name, lastModified:properties.lastModified}" -o tsv)
    
    while IFS=$'\t' read -r container_name last_modified; do
        # Convert the last modified date to UTC and compare with the 7 days ago threshold
        if [[ "$last_modified" < "$seven_days_ago" ]]; then
            az storage container delete --name "$container_name" --account-name "$storage_account"
            echo "Deleted old container: $container_name"
        fi
    done <<< "$containers"

    echo "Old container cleanup completed."
}


# Function to perform mongodump and upload to Azure Storage
perform_mongodump() {
    local mongo_uri=$1
    local storage_account=$2
    local container_name_prefix=$3

    # Create a timestamped container name
    local timestamp=$(date -u +"%Y-%m-%d-%H-%M-%S")
    local container_name="${container_name_prefix}-${timestamp}"

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongodump; echo 'Local backup directory /tmp/mongodump deleted.'" EXIT
    
    echo "Starting mongodump..."
    mongodump --uri="$mongo_uri" --out="/tmp/mongodump"

    if [ $? -eq 0 ]; then
        echo "Backup created successfully at /tmp/mongodump."
        upload_to_azure "$storage_account" "$container_name" "/tmp/mongodump"
    else
        echo "mongodump failed."
        exit 1
    fi

    # Remove containers older than 7 days
    delete_old_containers "$storage_account" "$container_name_prefix"
}

# Function to perform mongorestore from Azure Storage
perform_mongorestore() {
    local mongo_uri=$1
    local storage_account=$2
    local container_name=$3

    # Ensure cleanup is done on exit
    trap "rm -rf /tmp/mongorestore; echo 'Local backup directory /tmp/mongorestore deleted.'" EXIT

    # Download backup from Azure Storage
    download_from_azure "$storage_account" "$container_name" "/tmp/mongorestore"

    echo "Starting mongorestore..."
    mongorestore --uri="$mongo_uri" "/tmp/mongorestore" --writeConcern {w:0}
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
        echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Container_Name_Prefix>"
        echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Timestamped_Container_Name>"
        exit 1
    fi

    local action=$1

    case $action in
        mongodump)
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongodump: $0 mongodump <MongoDB_URI> <Storage_Account_Name> <Container_Name_Prefix>"
                exit 1
            fi
            perform_mongodump "$2" "$3" "$4"
            ;;
        mongorestore)
            if [ "$#" -ne 4 ]; then
                echo "Usage for mongorestore: $0 mongorestore <MongoDB_URI> <Storage_Account_Name> <Timestamped_Container_Name>"
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
