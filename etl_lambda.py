import json
import boto3
import os
from datetime import datetime

# Conectando aos serviços da AWS
dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

# Variáveis de ambiente (serão passadas pelo Terraform)
TABLE_NAME = os.environ['TABLE_NAME']
BUCKET_NAME = os.environ['BUCKET_NAME']

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    
    
    # O método 'scan' varre e puxa todos os dados da tabela no DynamoDB
    response = table.scan()
    items = response.get('Items', [])
    
    if not items:
        print("Nenhum dado novo para exportar.")
        return {"statusCode": 200, "body": "Nenhum dado encontrado."}

  
    
    # pega cada registro e transformar em uma linha de texto.
    jsonl_data = ""
    for item in items:
        jsonl_data += json.dumps(item) + "\n"

  
    # Cria um caminho organizado por data no S3 (ex: 2026/07/05/dados.jsonl)
    hoje = datetime.now()
    caminho_s3 = f"dados-seguranca/{hoje.year}/{hoje.month:02d}/{hoje.day:02d}/extracao_{hoje.strftime('%H%M%S')}.jsonl"
    
    # Salvando o arquivo no Bucket S3
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=caminho_s3,
        Body=jsonl_data
    )
    
    print(f"Sucesso! {len(items)} registros salvos no Data Lake em: {caminho_s3}")
    
    return {
        "statusCode": 200,
        "body": f"ETL concluído. {len(items)} registros exportados."
    }