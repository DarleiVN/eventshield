terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # O backend deve ficar DENTRO do bloco terraform
  backend "s3" {
    bucket = "eventshield-state-2026-us-east-1"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# Fila SQS para retenção dos eventos do produtor
resource "aws_sqs_queue" "security_events_queue" {
  name                      = "eventshield-security-alerts-queue"
  message_retention_seconds = 86400 # Retém a mensagem por 24 horas em caso de falha do processador
  
  tags = {
    Project = "EventShield"
    Environment = "Dev"
  }
} # <-- Chave de fechamento do SQS adicionada aqui

# Persistência: Tabela DynamoDB para armazenar o histórico de eventos
resource "aws_dynamodb_table" "security_events_table" {
  name         = "eventshield-alerts-history"
  billing_mode = "PAY_PER_REQUEST" # Mantém 100% no Free Tier, pagando só se usar
  hash_key     = "event_id"        # Chave primária da tabela

  attribute {
    name = "event_id"
    type = "S" # Tipo: String
  }

  tags = {
    Project     = "EventShield"
    Environment = "Dev"
  }
}

# Notificação: Tópico SNS para alertas imediatos de severidade Crítica
resource "aws_sns_topic" "critical_alerts_topic" {
  name = "eventshield-critical-alerts"

  tags = {
    Project     = "EventShield"
    Environment = "Dev"
  }
}

# Assinatura do Tópico SNS (Atenção aqui!)
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.critical_alerts_topic.arn
  protocol  = "email"
  endpoint  = "darlei.niz09@gmail.com" # Substitua pelo seu e-mail real
}

# IAM Role para a execução da função Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "eventshield_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Política de permissões mínimas (SQS, DynamoDB, SNS e Logs)
resource "aws_iam_role_policy" "lambda_policy" {
  name = "eventshield_lambda_policy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permissão para ler e deletar mensagens consumidas da fila
        Effect   = "Allow"
        Action   = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.security_events_queue.arn
      },
      {
        # Permissão para gravar o histórico no banco NoSQL
        Effect   = "Allow"
        Action   = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.security_events_table.arn
      },
      {
        # Permissão para disparar o e-mail de alerta
        Effect   = "Allow"
        Action   = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.critical_alerts_topic.arn
      },
      {
        # Permissão básica para a Lambda escrever logs no CloudWatch
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}
# Empacota o código Python da Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_function.zip"
}

# Cria a Função Lambda
resource "aws_lambda_function" "security_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "eventshield-processor"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.security_events_table.name
      SNS_TOPIC_ARN = aws_sns_topic.critical_alerts_topic.arn
    }
  }
}

# Cria o gatilho: Faz a Lambda ler a fila SQS automaticamente
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.security_events_queue.arn
  function_name    = aws_lambda_function.security_processor.arn
  batch_size       = 1
}
# --- CONFIGURAÇÃO DO API GATEWAY (FASE 1) ---

# 1. Cria a Role que o API Gateway vai assumir
resource "aws_iam_role" "api_gateway_sqs_role" {
  name = "eventshield-api-gateway-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

# 2. Cria a política que permite enviar mensagens para a nossa fila SQS
resource "aws_iam_policy" "api_gateway_sqs_policy" {
  name        = "eventshield-api-gateway-sqs-policy"
  description = "Permite que o API Gateway envie mensagens para o SQS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["sqs:SendMessage"]
        Effect   = "Allow"
        Resource = aws_sqs_queue.security_events_queue.arn
      }
    ]
  })
}

# 3. Anexa a política à Role
resource "aws_iam_role_policy_attachment" "api_gateway_sqs_attach" {
  role       = aws_iam_role.api_gateway_sqs_role.name
  policy_arn = aws_iam_policy.api_gateway_sqs_policy.arn
}

# 4. Cria o esqueleto do API Gateway
resource "aws_api_gateway_rest_api" "eventshield_api" {
  name        = "eventshield-api"
  description = "Porta de entrada pública para os alertas do EventShield"
}

# 5. Cria o caminho do endpoint (/alerts)
resource "aws_api_gateway_resource" "alerts_resource" {
  rest_api_id = aws_api_gateway_rest_api.eventshield_api.id
  parent_id   = aws_api_gateway_rest_api.eventshield_api.root_resource_id
  path_part   = "alerts"
}

# 6. Busca o ID da conta AWS
data "aws_caller_identity" "current" {}

# 7. Cria o método HTTP (POST)
resource "aws_api_gateway_method" "alerts_method" {
  rest_api_id   = aws_api_gateway_rest_api.eventshield_api.id
  resource_id   = aws_api_gateway_resource.alerts_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# 8. Conecta o POST do API Gateway ao SQS
resource "aws_api_gateway_integration" "sqs_integration" {
  rest_api_id             = aws_api_gateway_rest_api.eventshield_api.id
  resource_id             = aws_api_gateway_resource.alerts_resource.id
  http_method             = aws_api_gateway_method.alerts_method.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  credentials             = aws_iam_role.api_gateway_sqs_role.arn
  uri                     = "arn:aws:apigateway:us-east-1:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.security_events_queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

# 9. Configura a resposta HTTP padrão (200 OK)
resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.eventshield_api.id
  resource_id = aws_api_gateway_resource.alerts_resource.id
  http_method = aws_api_gateway_method.alerts_method.http_method
  status_code = "200"
}

# 10. Configura a resposta da integração (sucesso do SQS)
resource "aws_api_gateway_integration_response" "integration_response_200" {
  rest_api_id = aws_api_gateway_rest_api.eventshield_api.id
  resource_id = aws_api_gateway_resource.alerts_resource.id
  http_method = aws_api_gateway_method.alerts_method.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  depends_on = [aws_api_gateway_integration.sqs_integration]
}

# 11. Cria o Deployment da API
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.eventshield_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.alerts_resource.id,
      aws_api_gateway_method.alerts_method.id,
      aws_api_gateway_integration.sqs_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 12. Cria o Stage (Ambiente dev)
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.eventshield_api.id
  stage_name    = "dev"
}

# 13. Exibe a URL gerada no terminal
output "api_url" {
  value       = "${aws_api_gateway_stage.api_stage.invoke_url}/${aws_api_gateway_resource.alerts_resource.path_part}"
  description = "URL publica da API Gateway"
}
# ==========================================
# FASE 4: DATA LAKE & ETL (Analytics)
# ==========================================

# 1. Bucket S3 para o Data Lake (Armazenamento de longo prazo)
resource "aws_s3_bucket" "data_lake" {
  bucket = "eventshield-datalake-darlei-2026" # Se der erro de nome, adicione números aleatórios aqui
}

# 2. Identidade (Role) para o Robô de ETL
resource "aws_iam_role" "etl_lambda_role" {
  name = "eventshield_etl_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# 3. Permissões do Robô de ETL (Ler DynamoDB e Escrever no S3)
resource "aws_iam_policy" "etl_lambda_policy" {
  name        = "eventshield_etl_policy"
  description = "Permite a Lambda ETL ler do DynamoDB e gravar no S3 Data Lake"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permissão para extrair os dados da tabela
        Effect = "Allow"
        Action = ["dynamodb:Scan"]
        Resource = aws_dynamodb_table.security_events_table.arn
      },
      {
        # Permissão para salvar os arquivos gerados no Data Lake
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.data_lake.arn}/*"
      },
      {
        # Permissão para gerar logs no CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# 4. Anexar as permissões à identidade do Robô
resource "aws_iam_role_policy_attachment" "etl_lambda_attach" {
  role       = aws_iam_role.etl_lambda_role.name
  policy_arn = aws_iam_policy.etl_lambda_policy.arn
}