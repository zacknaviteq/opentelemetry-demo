# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Postgres with the demo schema baked in (compose bind-mounts src/postgresql/init.sql).
ARG POSTGRES_IMAGE=postgres:18.6
FROM ${POSTGRES_IMAGE}
COPY src/postgresql/init.sql /docker-entrypoint-initdb.d/init.sql
