# Linux/amd64 toolbox that matches the GitHub Actions runner used upstream,
# so AWSGoat deploys the same way from any host that has Docker.
FROM --platform=linux/amd64 hashicorp/terraform:1.10.5

RUN apk add --no-cache bash python3 py3-boto3 aws-cli jq tar

COPY awsgoat.sh /usr/local/bin/awsgoat
RUN chmod +x /usr/local/bin/awsgoat

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/awsgoat"]
