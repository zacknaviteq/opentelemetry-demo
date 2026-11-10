#!/usr/bin/python

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

"""Start/stop the otel-demo ECS services (EventBridge Scheduler target).

Event: {"action": "start" | "stop"}
    start -> desiredCount=1 for every service in SERVICES (includes load-generator)
    stop  -> desiredCount=0 for every service in the cluster
"""

import os

import boto3

ecs = boto3.client("ecs")


def _all_services(cluster):
    names = []
    for page in ecs.get_paginator("list_services").paginate(cluster=cluster):
        names.extend(arn.rsplit("/", 1)[-1] for arn in page["serviceArns"])
    return names


def handler(event, _context):
    action = (event or {}).get("action")
    cluster = os.environ["CLUSTER"]
    if action == "start":
        targets = {s: 1 for s in os.environ["SERVICES"].split(",") if s}
    elif action == "stop":
        targets = {s: 0 for s in _all_services(cluster)}
    else:
        raise ValueError(f"unknown action {action!r}")

    changed = []
    for service, count in sorted(targets.items()):
        ecs.update_service(cluster=cluster, service=service, desiredCount=count)
        changed.append(f"{service}={count}")
    print(f"{action}: {', '.join(changed)}")
    return {"action": action, "services": changed}
