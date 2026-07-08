import json
import boto3
import os
import urllib.request  

# Inicializa os clientes fora do handler para reutilização de conexões
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')

TABLE_NAME = os.environ.get('TABLE_NAME', 'eventshield-alerts-history')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', 'arn:aws:sns:us-east-1:385074782977:eventshield-critical-alerts')

def get_ip_location(ip):
    """
    Consulta a API pública ip-api para obter dados geográficos do IP.
    Retorna um dicionário com os dados enriquecidos ou valores padrão em caso de falha.
    """
    url = f"http://ip-api.com/json/{ip}?fields=status,country,regionName,city,isp"
    try:
        # Configura uma requisição com User-Agent para evitar bloqueios e um timeout curto de 3 segundos
        req = urllib.request.Request(url, headers={'User-Agent': 'EventShield-Lambda-Processor'})
        with urllib.request.urlopen(req, timeout=3) as response:
            data = json.loads(response.read().decode('utf-8'))
            
            if data.get('status') == 'success':
                return {
                    'country': data.get('country', 'Desconhecido'),
                    'region': data.get('regionName', 'Desconhecido'),
                    'city': data.get('city', 'Desconhecido'),
                    'isp': data.get('isp', 'Desconhecido')
                }
    except Exception as e:
        print(f"Aviso: Falha ao consultar a API de GeoIP para o IP {ip}: {str(e)}")
    
    # Retorno padrão de contingência caso a API externa falhe ou esteja indisponível
    return {
        'country': 'Desconhecido',
        'region': 'Desconhecido',
        'city': 'Desconhecido',
        'isp': 'Desconhecido'
    }

def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    
    for record in event['Records']:
        # 1. Desempacota o JSON recebido do SQS através da API Gateway
        payload = json.loads(record['body'])
        source_ip = payload.get('source_ip', '')
        print(f"Processando evento de segurança: {payload.get('event_id')} | IP de Origem: {source_ip}")
        
        # 2. Executa o enriquecimento de dados geográficos
        geo_information = get_ip_location(source_ip)
        payload.update(geo_information)  
        
        # 3. Grava o histórico de auditoria já enriquecido no DynamoDB
        table.put_item(Item=payload)
        print("Evento enriquecido persistido no DynamoDB com sucesso.")
        
        # 4. Dispara o alerta imediato se a severidade for CRITICAL
        if payload.get('severity') == 'CRITICAL':
            mensagem_alerta = (
                f"🚨 ALERTA CRÍTICO DE SEGURANÇA ENRIQUECIDO (EventShield)\n"
                f"====================================================\n"
                f"ID do Evento: {payload.get('event_id')}\n"
                f"Tipo de Ataque: {payload.get('event_type')}\n"
                f"IP de Origem: {payload.get('source_ip')}\n"
                f"Localização: {payload.get('city')}, {payload.get('region')} - {payload.get('country')}\n"
                f"Provedor (ISP): {payload.get('isp')}\n"
                f"Ferramenta: {payload.get('user_agent')}\n"
                f"Timestamp: {payload.get('timestamp')}\n\n"
                f"Ação Recomendada: Avalie o bloqueio imediato deste IP no Firewall com base na origem detectada."
            )
            
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"EventShield: {payload.get('event_type')} [{payload.get('country')}] Detectado",
                Message=mensagem_alerta
            )
            print("Notificação crítica enriquecida enviada ao SNS.")
            
    return {
        'statusCode': 200,
        'body': json.dumps('Eventos processados e enriquecidos com sucesso pelo EventShield!')
    }