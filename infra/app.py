#!/usr/bin/env python3
"""
app.py — HoehnPhotos CDK application entry point.

This is a *separate* CDK app, independent of any other infrastructure.
It can be deployed to any AWS account that has CDK bootstrapped.

Usage:
    cd infra/
    pip install -r requirements.txt
    cdk synth          # generate CloudFormation template
    cdk diff           # compare with deployed stack
    cdk deploy         # deploy to AWS (requires AWS credentials)
    cdk destroy        # tear down all resources
"""

from aws_cdk import App
from hoehn_photos_cdk.stacks.sync_stack import SyncStack

app = App()

# Pull context values from cdk.json (overridable via --context env=prod)
env_name = app.node.try_get_context("env") or "dev"
region = app.node.try_get_context("region") or "us-east-1"

SyncStack(
    app,
    "HoehnPhotosSync",
    description=(
        "HoehnPhotosOrganizer cloud sync stack. "
        "Provides S3 private bucket, DynamoDB thread table, "
        "and placeholder Lambda + API Gateway for Wave 2."
    ),
)

app.synth()
