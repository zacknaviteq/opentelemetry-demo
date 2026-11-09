# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Service catalogue: one ECS service per compose service, translated from
# compose.yaml + compose.full.yaml + compose.agent.yaml. Compose hostnames are
# replaced by Cloud Map FQDNs (<svc>.otel-demo.local) because Fargate tasks do
# not get the namespace as a DNS search domain.
#
# Images: <ecr>/opentelemetry-demo:latest-<image>. CI pushes <sha>-<image> and
# re-points latest-<image>, then forces a new deployment.

locals {
  ns = aws_service_discovery_private_dns_namespace.this.name

  host = { for s in [
    "ad", "agent", "astronomy-db", "cart", "chatbot", "checkout", "currency", "email",
    "flagd", "frontend", "frontend-proxy", "image-provider", "kafka", "load-generator",
    "mcp", "otel-collector", "payment", "product-catalog", "quote", "recommendation",
    "shipping", "valkey-cart",
    # Not deployed (Envoy routes stay unresolvable, as in compose without the
    # observability/extras layers):
    "grafana", "jaeger", "opamp-server", "firepit", "telemetry-docs",
  ] : s => "${s}.${local.ns}" }

  otlp_grpc = "http://${local.host["otel-collector"]}:4317"
  otlp_http = "http://${local.host["otel-collector"]}:4318"
  res_attrs = "service.namespace=opentelemetry-demo,service.version=${var.demo_version}"

  metrics_env = {
    OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE        = "cumulative"
    OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION = "explicit_bucket_histogram"
  }
  flagd_env = {
    FLAGD_HOST = local.host["flagd"]
    FLAGD_PORT = "8013"
  }

  addr = {
    ad              = "${local.host["ad"]}:9555"
    cart            = "${local.host["cart"]}:7070"
    checkout        = "${local.host["checkout"]}:5050"
    currency        = "${local.host["currency"]}:7001"
    email           = "http://${local.host["email"]}:6060"
    payment         = "${local.host["payment"]}:50051"
    product_catalog = "${local.host["product-catalog"]}:3550"
    quote           = "http://${local.host["quote"]}:8090"
    recommendation  = "${local.host["recommendation"]}:9001"
    shipping        = "http://${local.host["shipping"]}:50050"
    kafka           = "${local.host["kafka"]}:9092"
    valkey          = "${local.host["valkey-cart"]}:6379"
    frontend        = "${local.host["frontend"]}:8080"
  }

  public_url = "http://${aws_lb.this.dns_name}"

  # capacity: "spot"  => FARGATE_SPOT
  #           "ondemand" => FARGATE
  #           "proxy" => FARGATE base 1 (first task on-demand), extra tasks on Spot
  # role:     "default" | "collector" | "agent"
  services = {
    ad = {
      cpu = 256, memory = 1024, capacity = "spot", role = "default"
      containers = [{
        name = "ad", image = "ad", ports = [9555]
        env = merge(local.metrics_env, local.flagd_env, {
          AD_PORT                                 = "9555"
          AD_PROMETHEUS_PORT                      = "9465"
          OTEL_EXPORTER_OTLP_ENDPOINT             = local.otlp_http
          OTEL_RESOURCE_ATTRIBUTES                = "${local.res_attrs},service.criticality=medium"
          OTEL_LOGS_EXPORTER                      = "otlp"
          OTEL_SERVICE_NAME                       = "ad"
          OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION = "latest"
        })
      }]
    }

    cart = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "cart", image = "cart", ports = [7070]
        env = merge(local.metrics_env, local.flagd_env, {
          CART_PORT                   = "7070"
          VALKEY_ADDR                 = local.addr.valkey
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_grpc
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=high"
          OTEL_SERVICE_NAME           = "cart"
          ASPNETCORE_HTTP_PORTS       = "7070"
        })
      }]
    }

    checkout = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "checkout", image = "checkout", ports = [5050]
        env = merge(local.metrics_env, local.flagd_env, {
          CHECKOUT_PORT               = "5050"
          CART_ADDR                   = local.addr.cart
          CURRENCY_ADDR               = local.addr.currency
          EMAIL_ADDR                  = local.addr.email
          PAYMENT_ADDR                = local.addr.payment
          PRODUCT_CATALOG_ADDR        = local.addr.product_catalog
          SHIPPING_ADDR               = local.addr.shipping
          KAFKA_ADDR                  = local.addr.kafka
          KAFKA_TOPIC                 = "orders"
          GOMEMLIMIT                  = "200MiB"
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http
          OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
          OTEL_GO_X_OBSERVABILITY     = "true"
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=critical"
          OTEL_SERVICE_NAME           = "checkout"
        })
      }]
    }

    currency = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "currency", image = "currency", ports = [7001]
        env = merge(local.metrics_env, {
          CURRENCY_PORT               = "7001"
          IPV6_ENABLED                = "false"
          VERSION                     = var.demo_version
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_grpc
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=high"
          OTEL_SERVICE_NAME           = "currency"
        })
      }]
    }

    email = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "email", image = "email", ports = [6060]
        env = merge(local.metrics_env, local.flagd_env, {
          APP_ENV                     = "production"
          EMAIL_PORT                  = "6060"
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=medium"
          OTEL_SERVICE_NAME           = "email"
        })
      }]
    }

    frontend = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "frontend", image = "frontend", ports = [8080]
        env = merge(local.metrics_env, local.flagd_env, {
          PORT                                      = "8080"
          FRONTEND_ADDR                             = local.addr.frontend
          AD_ADDR                                   = local.addr.ad
          CART_ADDR                                 = local.addr.cart
          CHECKOUT_ADDR                             = local.addr.checkout
          CURRENCY_ADDR                             = local.addr.currency
          PRODUCT_CATALOG_ADDR                      = local.addr.product_catalog
          RECOMMENDATION_ADDR                       = local.addr.recommendation
          SHIPPING_ADDR                             = local.addr.shipping
          OTEL_EXPORTER_OTLP_ENDPOINT               = local.otlp_grpc
          OTEL_RESOURCE_ATTRIBUTES                  = "${local.res_attrs},service.criticality=critical"
          ENV_PLATFORM                              = "aws"
          OTEL_SERVICE_NAME                         = "frontend"
          PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = "${local.public_url}/otlp-http/v1/traces"
          WEB_OTEL_SERVICE_NAME                     = "frontend-web"
          OTEL_COLLECTOR_HOST                       = local.host["otel-collector"]
        })
      }]
    }

    frontend-proxy = {
      cpu = 256, memory = 512, capacity = "proxy", role = "default"
      containers = [{
        name = "frontend-proxy", image = "frontend-proxy", ports = [8080, 10000]
        env = merge(local.flagd_env, {
          FRONTEND_PORT            = "8080"
          FRONTEND_HOST            = local.host["frontend"]
          LOCUST_WEB_HOST          = local.host["load-generator"]
          LOCUST_WEB_PORT          = "8089"
          GRAFANA_HOST             = local.host["grafana"]
          GRAFANA_PORT             = "3000"
          JAEGER_HOST              = local.host["jaeger"]
          JAEGER_UI_PORT           = "16686"
          OPAMP_SERVER_HOST        = local.host["opamp-server"]
          OPAMP_SERVER_UI_PORT     = "4321"
          OTEL_COLLECTOR_HOST      = local.host["otel-collector"]
          OTEL_COLLECTOR_PORT_GRPC = "4317"
          OTEL_COLLECTOR_PORT_HTTP = "4318"
          IMAGE_PROVIDER_HOST      = local.host["image-provider"]
          IMAGE_PROVIDER_PORT      = "8081"
          OTEL_RESOURCE_ATTRIBUTES = "${local.res_attrs},service.criticality=critical"
          OTEL_SERVICE_NAME        = "frontend-proxy"
          OTEL_SERVICE_NAMESPACE   = "opentelemetry-demo"
          ENVOY_ADDR               = "0.0.0.0"
          ENVOY_PORT               = "8080"
          ENVOY_ADMIN_PORT         = "10000"
          FIREPIT_HOST             = local.host["firepit"]
          FIREPIT_PORT             = "8080"
          # flagd-ui runs in the flagd task, so it shares the flagd hostname.
          FLAGD_UI_HOST       = local.host["flagd"]
          FLAGD_UI_PORT       = "4000"
          TELEMETRY_DOCS_HOST = local.host["telemetry-docs"]
          TELEMETRY_DOCS_PORT = "8000"
          CHATBOT_HOST        = local.host["chatbot"]
          CHATBOT_PORT        = "7860"
        })
      }]
    }

    image-provider = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "image-provider", image = "image-provider", ports = [8081]
        env = {
          IMAGE_PROVIDER_PORT      = "8081"
          OTEL_COLLECTOR_HOST      = local.host["otel-collector"]
          OTEL_COLLECTOR_PORT_GRPC = "4317"
          OTEL_RESOURCE_ATTRIBUTES = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME        = "image-provider"
        }
      }]
    }

    load-generator = {
      cpu = 512, memory = 2048, capacity = "spot", role = "default", always_off = true
      containers = [{
        name = "load-generator", image = "load-generator", ports = [8089]
        env = merge(local.metrics_env, local.flagd_env, {
          LOCUST_WEB_PORT                          = "8089"
          LOCUST_USERS                             = "5"
          LOCUST_HOST                              = "http://${local.host["frontend-proxy"]}:8080"
          LOCUST_HEADLESS                          = "false"
          LOCUST_AUTOSTART                         = "true"
          LOCUST_BROWSER_TRAFFIC_ENABLED           = "true"
          LOCUST_HTTP_USER_WEIGHT                  = "9"
          LOCUST_BROWSER_USER_WEIGHT               = "1"
          LOCUST_WEB_HOST                          = "0.0.0.0"
          FLAGD_OFREP_PORT                         = "8016"
          AGENT_ENDPOINT                           = local.host["agent"]
          AGENT_PORT                               = "8010"
          OTEL_EXPORTER_OTLP_ENDPOINT              = local.otlp_grpc
          OTEL_RESOURCE_ATTRIBUTES                 = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                        = "load-generator"
          OTEL_PYTHON_SDK_INTERNAL_METRICS_ENABLED = "true"
          PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION   = "python"
        })
      }]
    }

    payment = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "payment", image = "payment", ports = [50051]
        env = merge(local.metrics_env, local.flagd_env, {
          IPV6_ENABLED                = "false"
          PAYMENT_PORT                = "50051"
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_grpc
          OTEL_EXPORTER_OTLP_PROTOCOL = "grpc"
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=critical"
          OTEL_SERVICE_NAME           = "payment"
        })
      }]
    }

    product-catalog = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "product-catalog", image = "product-catalog", ports = [3550]
        env = merge(local.metrics_env, local.flagd_env, {
          PRODUCT_CATALOG_PORT          = "3550"
          GOMEMLIMIT                    = "200MiB"
          OTEL_EXPORTER_OTLP_ENDPOINT   = local.otlp_grpc
          OTEL_GO_X_OBSERVABILITY       = "true"
          OTEL_RESOURCE_ATTRIBUTES      = "${local.res_attrs},service.criticality=high"
          OTEL_SERVICE_NAME             = "product-catalog"
          OTEL_CONFIG_FILE              = "/otel-config.yml"
          OTEL_SEMCONV_STABILITY_OPT_IN = "database"
          # Demo credentials from upstream src/postgresql/init.sql (private DB, no persistence).
          DB_CONNECTION_STRING = "postgres://astronomy_user:astronomy_password@${local.host["astronomy-db"]}/astronomy_db?sslmode=disable"
        })
      }]
    }

    quote = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "quote", image = "quote", ports = [8090]
        env = merge(local.metrics_env, {
          IPV6_ENABLED                      = "false"
          QUOTE_PORT                        = "8090"
          OTEL_EXPORTER_OTLP_ENDPOINT       = local.otlp_http
          OTEL_PHP_AUTOLOAD_ENABLED         = "true"
          OTEL_PHP_INTERNAL_METRICS_ENABLED = "true"
          OTEL_RESOURCE_ATTRIBUTES          = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                 = "quote"
        })
      }]
    }

    recommendation = {
      cpu = 256, memory = 1024, capacity = "spot", role = "default"
      containers = [{
        name = "recommendation", image = "recommendation", ports = [9001]
        env = merge(local.metrics_env, local.flagd_env, {
          RECOMMENDATION_PORT                     = "9001"
          PRODUCT_CATALOG_ADDR                    = local.addr.product_catalog
          OTEL_EXPORTER_OTLP_ENDPOINT             = local.otlp_http
          OTEL_RESOURCE_ATTRIBUTES                = "${local.res_attrs},service.criticality=medium"
          OTEL_SERVICE_NAME                       = "recommendation"
          OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION = "latest"
        })
      }]
    }

    shipping = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "shipping", image = "shipping", ports = [50050]
        env = merge(local.metrics_env, local.flagd_env, {
          IPV6_ENABLED                = "false"
          SHIPPING_PORT               = "50050"
          QUOTE_ADDR                  = local.addr.quote
          OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http
          OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
          OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=high"
          OTEL_SERVICE_NAME           = "shipping"
        })
      }]
    }

    # flagd + flagd-ui share the flag file through a task volume, seeded by an
    # init container (compose bind-mounts ./src/flagd into both).
    flagd = {
      cpu     = 256, memory = 1024, capacity = "spot", role = "default"
      volumes = ["flags"]
      containers = [
        {
          name   = "flagd-init", image = "flagd-init", essential = false
          mounts = [{ sourceVolume = "flags", containerPath = "/data", readOnly = false }]
          env    = {}
        },
        {
          name       = "flagd", image = "flagd", ports = [8013, 8016]
          command    = ["start", "--uri", "file:/etc/flagd/demo.flagd.json"]
          mounts     = [{ sourceVolume = "flags", containerPath = "/etc/flagd", readOnly = false }]
          depends_on = [{ containerName = "flagd-init", condition = "SUCCESS" }]
          env = {
            OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http
            OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
            GOMEMLIMIT                  = "60MiB"
            OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=low"
            OTEL_SERVICE_NAME           = "flagd"
          }
        },
        {
          name       = "flagd-ui", image = "flagd-ui", ports = [4000]
          mounts     = [{ sourceVolume = "flags", containerPath = "/app/data", readOnly = false }]
          depends_on = [{ containerName = "flagd-init", condition = "SUCCESS" }]
          env = merge(local.metrics_env, {
            FLAGD_UI_PORT               = "4000"
            OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_http
            OTEL_RESOURCE_ATTRIBUTES    = "${local.res_attrs},service.criticality=low"
            OTEL_SERVICE_NAME           = "flagd-ui"
            # Upstream demo value from compose.yaml (not a real secret).
            SECRET_KEY_BASE = "yYrECL4qbNwleYInGJYvVnSkwJuSQJ4ijPTx5tirGUXrbznFIBFVJdPl5t6O9ASw"
            PHX_HOST        = "localhost"
          })
        },
      ]
    }

    astronomy-db = {
      cpu = 256, memory = 512, capacity = "ondemand", role = "default"
      containers = [{
        name    = "astronomy-db", image = "astronomy-db", ports = [5432]
        command = ["postgres", "-c", "shared_preload_libraries=pg_stat_statements"]
        env = {
          POSTGRES_PASSWORD = "changeit" # upstream demo value; DB is private and ephemeral
        }
      }]
    }

    valkey-cart = {
      cpu = 256, memory = 512, capacity = "ondemand", role = "default"
      containers = [{
        name = "valkey-cart", image = "valkey-cart", ports = [6379], user = "valkey"
        env  = {}
      }]
    }

    otel-collector = {
      cpu = 512, memory = 1024, capacity = "ondemand", role = "collector"
      containers = [{
        name = "otel-collector", image = "otel-collector", ports = [4317, 4318, 13133]
        env = {
          AWS_REGION                = var.region
          GOMEMLIMIT                = "800MiB"
          TRACE_SAMPLING_PERCENTAGE = tostring(var.trace_sampling_percentage)
          OTEL_LOGS_LOG_GROUP       = aws_cloudwatch_log_group.otel_logs.name
          EMF_LOG_GROUP             = aws_cloudwatch_log_group.metrics.name
          EMF_NAMESPACE             = "OtelDemo"
        }
      }]
    }

    kafka = {
      cpu = 512, memory = 1024, capacity = "ondemand", role = "default"
      containers = [{
        name = "kafka", image = "kafka", ports = [9092]
        env = merge(local.metrics_env, {
          KAFKA_ADVERTISED_LISTENERS              = "PLAINTEXT://${local.addr.kafka}"
          KAFKA_LISTENERS                         = "PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093"
          KAFKA_CONTROLLER_QUORUM_VOTERS          = "1@localhost:9093"
          KAFKA_HEAP_OPTS                         = "-Xmx400m -Xms400m"
          OTEL_EXPORTER_OTLP_ENDPOINT             = local.otlp_http
          OTEL_RESOURCE_ATTRIBUTES                = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                       = "kafka"
          OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION = "latest"
        })
      }]
    }

    accounting = {
      cpu = 256, memory = 512, capacity = "spot", role = "default"
      containers = [{
        name = "accounting", image = "accounting"
        env = merge(local.metrics_env, {
          KAFKA_ADDR                                                          = local.addr.kafka
          KAFKA_TOPIC                                                         = "orders"
          OTEL_EXPORTER_OTLP_ENDPOINT                                         = local.otlp_http
          OTEL_RESOURCE_ATTRIBUTES                                            = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                                                   = "accounting"
          DB_CONNECTION_STRING                                                = "Host=${local.host["astronomy-db"]};Username=astronomy_user;Password=astronomy_password;Database=astronomy_db"
          OTEL_DOTNET_AUTO_TRACES_ENTITYFRAMEWORKCORE_INSTRUMENTATION_ENABLED = "false"
        })
      }]
    }

    fraud-detection = {
      cpu = 256, memory = 1024, capacity = "spot", role = "default"
      containers = [{
        name = "fraud-detection", image = "fraud-detection"
        env = merge(local.metrics_env, local.flagd_env, {
          KAFKA_ADDR                                                            = local.addr.kafka
          KAFKA_TOPIC                                                           = "orders"
          OTEL_EXPORTER_OTLP_ENDPOINT                                           = local.otlp_http
          OTEL_INSTRUMENTATION_KAFKA_EXPERIMENTAL_SPAN_ATTRIBUTES               = "true"
          OTEL_INSTRUMENTATION_MESSAGING_EXPERIMENTAL_RECEIVE_TELEMETRY_ENABLED = "true"
          OTEL_RESOURCE_ATTRIBUTES                                              = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                                                     = "fraud-detection"
          OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION                               = "latest"
        })
      }]
    }

    agent = {
      cpu = 256, memory = 1024, capacity = "spot", role = "agent"
      containers = [{
        name = "agent", image = "agent", ports = [8010]
        env = merge(local.flagd_env, {
          TRACELOOP_BASE_URL                       = local.otlp_http
          GRAPH_RECURSION_LIMIT                    = "25"
          MCP_ENDPOINT                             = local.host["mcp"]
          MCP_PORT                                 = "8011"
          MCP_ENABLED                              = "False"
          AGENT_ENDPOINT                           = local.host["agent"]
          AGENT_PORT                               = "8010"
          LLM_BASE_URL                             = "https://bedrock-runtime.${var.region}.amazonaws.com/openai/v1"
          LLM_MODEL                                = var.llm_model
          LLM_TLS_VERIFY                           = "True"
          LLM_AUTH                                 = "bedrock-iam" # short-term Bedrock key from the task role
          LLM_REGION                               = var.region
          LLM_MAX_TOKENS                           = tostring(var.llm_max_tokens)
          USE_VCR                                  = "False"
          VCR_MATCH_THRESHOLD                      = "0.85"
          APPLICATION_ENDPOINT                     = local.addr.frontend
          OTEL_EXPORTER_OTLP_INSECURE              = "true"
          OTEL_RESOURCE_ATTRIBUTES                 = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                        = "agent"
          OTEL_PYTHON_SDK_INTERNAL_METRICS_ENABLED = "true"
        })
      }]
    }

    mcp = {
      cpu = 256, memory = 1024, capacity = "spot", role = "default"
      containers = [{
        name = "mcp", image = "mcp", ports = [8011]
        env = {
          TRACELOOP_BASE_URL                       = local.otlp_http
          MCP_ENDPOINT                             = "0.0.0.0" # bind address
          MCP_PORT                                 = "8011"
          APPLICATION_ENDPOINT                     = local.addr.frontend
          OTEL_EXPORTER_OTLP_INSECURE              = "true"
          OTEL_RESOURCE_ATTRIBUTES                 = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                        = "mcp"
          OTEL_PYTHON_SDK_INTERNAL_METRICS_ENABLED = "true"
        }
      }]
    }

    chatbot = {
      cpu = 256, memory = 1024, capacity = "spot", role = "default"
      containers = [{
        name = "chatbot", image = "chatbot", ports = [7860]
        env = {
          AGENT_ENDPOINT                           = local.host["agent"]
          AGENT_PORT                               = "8010"
          CHATBOT_PORT                             = "7860"
          CHATBOT_ROOT_PATH                        = "/chatbot"
          OTEL_EXPORTER_OTLP_ENDPOINT              = local.otlp_http
          OTEL_EXPORTER_OTLP_INSECURE              = "true"
          OTEL_RESOURCE_ATTRIBUTES                 = "${local.res_attrs},service.criticality=low"
          OTEL_SERVICE_NAME                        = "chatbot"
          OTEL_PYTHON_SDK_INTERNAL_METRICS_ENABLED = "true"
        }
      }]
    }
  }

  # Services the schedule / site-control start (load-generator stays at 0).
  scheduled_services = sort([for k, v in local.task_specs : k if !v.always_off])

  # ECR image name => ECS service that runs it (used by CI to redeploy).
  image_to_service = merge([
    for svc, cfg in local.services : { for c in cfg.containers : c.image => svc }
  ]...)
}
