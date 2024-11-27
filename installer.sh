#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default values for command-line options
debug=false

# Parse command-line arguments
while [[ "$1" != "" ]]; do
    case $1 in
        --aws-region )      shift
                            AWS_REGION="$1"
                            ;;
        --clientId )        shift
                            clientId="$1"
                            ;;
        --debug )           debug=true
                            ;;
    esac
    shift
done

# Check if clientId and AWS_REGION were provided
if [[ -z "$clientId" ]]; then
    echo "Error: --clientId is required."
    exit 1
fi

if [[ -z "$AWS_REGION" ]]; then
    echo "Error: --aws-region is required."
    exit 1
fi

# Log function to control verbosity based on --debug flag
log() {
    if [ "$debug" = true ]; then
        echo "$@"
    fi
}

# Function to show progress with a loading icon
show_progress() {
    local message=$1
    local pid=$!
    local spin='-\|/'
    local i=0
    log "$message"
    while kill -0 $pid 2>/dev/null; do
        printf "\r[%c] %s" "${spin:$i:1}" "$message"
        i=$(( (i+1) % 4 ))
        sleep 0.1
    done
    printf "\r[✔] %s\n" "$message complete"
}

# Function to run commands with optional output suppression
run_command() {
    if [ "$debug" = true ]; then
        "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

# Check if AWS credentials are set as environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] ; then
    echo "Error: AWS Access Key ID, Secret Access Key must be set as environment variables."
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed."
    exit 1
fi

# Check if unzip is installed
if ! command -v unzip &>/dev/null; then
    log "Installing unzip utility..."
    echo "Installation started"
    run_command sudo apt-get update 
    run_command sudo apt-get install unzip -y
fi


# Determine system architecture and install the correct AWS CLI version
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
elif [ "$ARCH" = "aarch64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Check if AWS CLI is already installed
if command -v aws &> /dev/null; then
    log "AWS CLI is already installed. Skipping installation."
else
    # Install or update AWS CLI
    log "Installing AWS CLI for $ARCH..."
    run_command curl "$AWS_CLI_URL" -o "awscliv2.zip"
    run_command unzip awscliv2.zip
    run_command sudo ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli & show_progress "Installing Aws Cli"
    run_command rm -rf awscliv2.zip aws
fi

# Prompt user for clientId if not provided in arguments
if [ -z "$clientId" ]; then
    read -p "Enter the clientId: " clientId
    if [ -z "$clientId" ]; then
        echo "Error: clientId cannot be empty."
        exit 1
    fi
fi

# Generate a UUID for the Thing Name
thing_name=$(uuidgen)

AWS_ACCOUNT_ID="147997154696"
REPOSITORY_NAME="greengrass-docker"
IMAGE_TAG="latest"

# Full image path
IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPOSITORY_NAME}:${IMAGE_TAG}"

 
if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"; then
    echo "Error: Unable to authenticate Docker to ECR. Check your AWS credentials."
    exit 1
fi

# Check if the Docker image is available locally
if ! docker images | grep -q "${IMAGE_URI}"; then
    echo "Image ${IMAGE_URI} not found locally. Pulling from ECR..."

    # Pull the image from ECR
    docker pull "${IMAGE_URI}"

    if [ $? -eq 0 ]; then
        echo "Successfully pulled the image: ${IMAGE_URI}"
    else
        echo "Failed to pull the image: ${IMAGE_URI}"
        exit 1
    fi
else
    echo "Image ${IMAGE_URI} is already available locally."
fi



# Run the Docker container with the specified environment variables and volume mount
docker run -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
           -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
           -e AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
           -e CLIENT_ID="${clientId}" \
           -e THING_NAME="${thing_name}" \
           -e PROVISION="true" \
           -e AWS_REGION="${AWS_REGION}" \
           --volume=/dev:/dev\
           --volume="/outputFiles/${thing_name}":/outputFiles \
           --name "$thing_name" \
           -it -d "${IMAGE_URI}"

echo "Running docker container ..."

# Sleep for 15 seconds
sleep 20

if [ $? -eq 0 ]; then
    echo "Successfully started the container from the image: ${IMAGE_URI}."
else
    echo "Failed to start the container."
    exit 1
fi



echo "Greengrass Core Installation Complete!"
echo "----------------------------------------"
echo "Generated Device Id (UUID): $thing_name"
echo "Client ID: $clientId"
echo "AWS Region: $AWS_REGION"
echo "----------------------------------------"
