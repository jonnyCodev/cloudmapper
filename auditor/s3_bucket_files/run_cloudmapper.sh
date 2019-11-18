#!/bin/bash

echo "Runnning run_cloudmapper"

# Configure the AWS SDK so we can assume roles
mkdir ~/.aws
aws s3 cp s3://$S3_BUCKET/config ~/.aws/config

# Get CloudMapper config
aws s3 cp s3://$S3_BUCKET/config.json config.json
aws s3 cp s3://$S3_BUCKET/audit_config_override.yaml config/audit_config_override.yaml

mkdir collect_logs

children_pids=""

# Collect the metadata from the AWS accounts
while read account; do
    # For each account, run the following function in the background
    function collect {
        echo "*** Collecting from $1"
        python cloudmapper.py collect --profile $1 --account $1 > collect_logs/$1
        if [ $? -ne 0 ]; then
            echo "ERROR: The collect command had an error for account $1"
            # Record error
            aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
            # Record collection failed
            echo "  Collection from $1 failed"
        fi
          echo "*** Prepare for $1"
          python cloudmapper.py prepare --account $1
          echo "Copy the data.json file to account"
          cp web/data.json .
          mv data.json "$1".json

          #Remove white spaces
          tr -d " \t\n\r" <"$1".json> temp.json && mv temp.json "$1".json

          aws s3 cp "$1".json  s3://$S3_BUCKET/accounts-data-json/

    }
    collect $account &
    children_pids+="$! "
    echo "children pids = $children_pids"
done <<< "$(grep profile ~/.aws/config | sed 's/\[profile //' | sed 's/\]//')"

# Wait for all the collections to finish
sleep 10
wait $children_pids
sleep 10

echo "Done waiting, start audit"

# Audit the accounts and send the alerts to Slack
python cloudmapper.py audit --accounts all --markdown --minimum_severity $MINIMUM_ALERT_SEVERITY
if [ $? -ne 0 ]; then
    echo "ERROR: The audit command had an error"
    aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
fi

echo "Generate the report"
python cloudmapper.py report --accounts all
if [ $? -ne 0 ]; then
    echo "ERROR: The report command had an error"
    aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
fi

# Copy the collect data to the S3 bucket
aws s3 sync --delete account-data/ s3://$S3_BUCKET/account-data/
if [ $? -ne 0 ]; then
    echo "ERROR: syncing account-data failed"
    aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
fi

# Copy the logs to the S3 bucket
aws s3 sync --delete collect_logs/ s3://$S3_BUCKET/collect_logs/
if [ $? -ne 0 ]; then
    echo "ERROR: syncing the collection logs failed"
    aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
fi

# Copy the report to the S3 bucket
aws s3 sync --delete web/ s3://$S3_BUCKET/web/
if [ $? -ne 0 ]; then
    echo "ERROR: syncing web directory failed"
    aws cloudwatch put-metric-data --namespace cloudmapper --metric-data MetricName=errors,Value=1
fi

echo "Completed CloudMapper audit"
