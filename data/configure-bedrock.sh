#!/usr/bin/env bash

set -euo pipefail

container_name="${CONTAINER_NAME:-isabelle}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_aws_dir="${HOME}/.aws"
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
profile="${AWS_PROFILE:-default}"
model="${ASSISTANT_MODEL:-anthropic.claude-3-7-sonnet-20250219-v1:0}"
use_cris="${ASSISTANT_USE_CRIS:-true}"
copy_host_aws=true
run_checks=true

usage() {
    cat <<'EOF'
Usage: ./configure-bedrock.sh [options]

Options:
  --region REGION          AWS region for Bedrock and the plugin
  --profile PROFILE        AWS profile name to use for awscli checks
  --model MODEL_ID         Base Anthropic model ID for the Assistant
  --cris true|false        Enable or disable CRIS model prefixing
  --skip-copy-aws          Do not copy host ~/.aws into the running container
  --skip-checks            Skip aws sts / bedrock CLI verification
  --container NAME         Docker container name (default: isabelle)
  -h, --help               Show this message

Examples:
  ./configure-bedrock.sh
  ./configure-bedrock.sh --region eu-west-1 --profile bedrock
  ./configure-bedrock.sh --model anthropic.claude-sonnet-4-20250514-v1:0
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --region)
            region="$2"
            shift 2
            ;;
        --profile)
            profile="$2"
            shift 2
            ;;
        --model)
            model="$2"
            shift 2
            ;;
        --cris)
            use_cris="$2"
            shift 2
            ;;
        --skip-copy-aws)
            copy_host_aws=false
            shift
            ;;
        --skip-checks)
            run_checks=false
            shift
            ;;
        --container)
            container_name="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$use_cris" in
    true|false) ;;
    *)
        echo "--cris must be true or false" >&2
        exit 2
        ;;
esac

ensure_container() {
    if ! docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "Container '$container_name' not found. Start it with $script_dir/run.sh first." >&2
        exit 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$container_name")" != "true" ]; then
        docker start "$container_name" >/dev/null
    fi
}

copy_host_aws_into_container() {
    if [ "$copy_host_aws" != true ]; then
        return
    fi
    if [ ! -d "$host_aws_dir" ] || [ -z "$(find "$host_aws_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        return
    fi
    if docker exec "$container_name" bash -lc '[ -d /root/.aws ] && [ -n "$(find /root/.aws -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]'; then
        return
    fi
    docker exec "$container_name" bash -lc 'mkdir -p /root/.aws'
    docker cp "$host_aws_dir/." "$container_name:/root/.aws/"
}

docker_set_file_props() {
    docker exec \
        -e REGION="$region" \
        -e MODEL_ID="$model" \
        -e USE_CRIS="$use_cris" \
        -e PROFILE_NAME="$profile" \
        "$container_name" \
        bash -lc '
            set -euo pipefail

            set_prop() {
                local file="$1"
                local key="$2"
                local value="$3"
                local escaped
                mkdir -p "$(dirname "$file")"
                touch "$file"
                escaped=$(printf "%s" "$value" | sed "s/[\\/&]/\\\\&/g")
                if grep -q "^${key}=" "$file"; then
                    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
                else
                    printf "%s=%s\n" "$key" "$value" >> "$file"
                fi
            }

            props=/root/.isabelle/Isabelle2025-2/jedit/properties
            set_prop "$props" assistant.aws.region "$REGION"
            set_prop "$props" assistant.model.id "$MODEL_ID"
            set_prop "$props" assistant.use.cris "$USE_CRIS"

            mkdir -p /root/.aws
            if [ ! -s /root/.aws/config ]; then
                if [ "$PROFILE_NAME" = "default" ]; then
                    printf "[default]\nregion = %s\n" "$REGION" > /root/.aws/config
                else
                    printf "[profile %s]\nregion = %s\n" "$PROFILE_NAME" "$REGION" > /root/.aws/config
                fi
            fi
        '
}

run_aws_checks() {
    if [ "$run_checks" != true ]; then
        return
    fi

    if ! docker exec "$container_name" bash -lc 'command -v aws >/dev/null 2>&1'; then
        return
    fi

    echo "== aws sts get-caller-identity =="
    if ! docker exec \
        -e AWS_PROFILE="$profile" \
        -e AWS_REGION="$region" \
        -e AWS_DEFAULT_REGION="$region" \
        "$container_name" \
        bash -lc 'aws sts get-caller-identity --output json'; then
        echo "WARN: AWS credentials are not usable in the container yet." >&2
        return
    fi

    echo
    echo "== aws bedrock list-foundation-models (Anthropic only) =="
    docker exec \
        -e AWS_PROFILE="$profile" \
        -e AWS_REGION="$region" \
        -e AWS_DEFAULT_REGION="$region" \
        "$container_name" \
        bash -lc '
            aws bedrock list-foundation-models \
                --region "$AWS_REGION" \
                --by-output-modality TEXT \
                --query "modelSummaries[?contains(modelId, '\''anthropic.'\'')].[modelId]" \
                --output text
        '
}

ensure_container
copy_host_aws_into_container
docker_set_file_props
run_aws_checks

cat <<EOF
Configured container '$container_name' for Bedrock.
  region:  $region
  profile: $profile
  model:   $model
  cris:    $use_cris

Plugin settings were written to:
  /root/.isabelle/Isabelle2025-2/jedit/properties

If you are using new host-side AWS credentials/config, restart or recreate the container
or rerun this script to sync ~/.aws into the current container.
EOF
