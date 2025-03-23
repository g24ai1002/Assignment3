#!/bin/bash

# Configuration
GCP_REGION="asia-south1-a"
LOCAL_SOURCE="$HOME/local/dataset"
REMOTE_DEST="$HOME"
GCP_LOGIN="clouduser"
CPU_LIMIT=75
APP_FOLDER="webapp"
APP_PORT="8080"

# Authenticate with Google Cloud
export GOOGLE_APPLICATION_CREDENTIALS="vccassignment3-454612-6c97b429ceaa.json"
gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
gcloud config set project assignment3-454612

echo "Checking system CPU utilization..."
CPU_LOAD=$(top -bn1 | awk '/Cpu\(s\)/ {print 100 - $8}')
echo "Current CPU Load: $CPU_LOAD%"

# Fetch the current running instance name (if any)
VM_INSTANCE=$(gcloud compute instance-groups managed list-instances scale-group --zone $GCP_REGION --format="value(name)" | head -n 1)

# Deploy VM if CPU exceeds threshold and no instance is running
if (( $(echo "$CPU_LOAD > $CPU_LIMIT" | bc -l) )); then
    if [ -z "$VM_INSTANCE" ]; then
        echo "High CPU load detected. Deploying new VM..."

        gcloud compute instance-templates create auto-vm-template \
            --image-family=ubuntu-2204-lts \
            --image-project=ubuntu-os-cloud \
            --machine-type=e2-medium \
            --boot-disk-size=10GB \
            --tags=http-server,https-server

        gcloud compute instance-groups managed create scale-group \
            --base-instance-name=auto-vm \
            --template=auto-vm-template \
            --size=1 \
            --zone=$GCP_REGION

        gcloud compute instance-groups managed set-autoscaling scale-group \
            --max-num-replicas=5 \
            --min-num-replicas=1 \
            --target-cpu-utilization=0.75 \
            --cool-down-period=60 \
            --zone=$GCP_REGION

        sleep 30
        NEW_INSTANCE=$(gcloud compute instance-groups managed list-instances scale-group --zone=$GCP_REGION --format="value(name)" | head -n 1)

        echo "Transferring files to VM..."
        gcloud compute scp --recurse "$LOCAL_SOURCE" "$GCP_LOGIN@$NEW_INSTANCE:$REMOTE_DEST" --zone="$GCP_REGION"

        echo "Setting up the web application..."
        gcloud compute ssh $NEW_INSTANCE --zone $GCP_REGION --command "
          sudo apt update && sudo apt install -y nodejs npm nginx
          mkdir -p /home/$USER/$APP_FOLDER && cd /home/$USER/$APP_FOLDER
          npm init -y && npm install express
          echo \"const express = require('express'); const app = express(); app.get('/', (req, res) => res.send('Hello from $NEW_INSTANCE')); app.listen($APP_PORT);\" > app.js
          nohup node app.js &
          sudo bash -c 'cat > /etc/nginx/sites-available/default <<EOF
          server {
            listen 80;
            location / {
              proxy_pass http://localhost:$APP_PORT;
              proxy_http_version 1.1;
              proxy_set_header Upgrade \$http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host \$host;
            }
          }
          EOF'
          sudo systemctl restart nginx
        "
        echo "Deployment successful on $NEW_INSTANCE"
    else
        echo "An active VM is already running. Skipping deployment."
    fi

# Shutdown VM if CPU usage drops below threshold
elif (( $(echo "$CPU_LOAD < $CPU_LIMIT" | bc -l) )); then
    if [ -n "$VM_INSTANCE" ]; then
        echo "CPU load is low. Terminating the VM..."
        gcloud compute instance-groups managed delete scale-group --zone $GCP_REGION --quiet
    else
        echo "No running instances detected. Nothing to shut down."
    fi
fi
