'use strict';

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { SSMClient, GetParametersByPathCommand } = require('@aws-sdk/client-ssm');

const client = new SecretsManagerClient({ region: process.env.AWS_REGION || 'us-east-2' });
const ssmClient = new SSMClient({ region: process.env.AWS_REGION || 'us-east-2' });

const cache = {};

const getSecret = async (secretName) => {
  if (cache[secretName]) return cache[secretName];
  try {
    const response = await client.send(new GetSecretValueCommand({ SecretId: secretName }));
    const secret = JSON.parse(response.SecretString);
    cache[secretName] = secret;
    return secret;
  } catch (err) {
    console.error(`Failed to fetch secret ${secretName}:`, err.message);
    throw err;
  }
};

const getSSMParams = async (path) => {
  try {
    const response = await ssmClient.send(new GetParametersByPathCommand({
      Path: path, Recursive: true, WithDecryption: true,
    }));
    return response.Parameters.reduce((acc, p) => {
      const key = p.Name.split('/').pop();
      acc[key] = p.Value;
      return acc;
    }, {});
  } catch (err) {
    console.error(`Failed to fetch SSM params at ${path}:`, err.message);
    return {};
  }
};

const loadConfig = async () => {
  const PROJECT = process.env.PROJECT_NAME || 'ecom-microservices';
  const ENV     = process.env.ENVIRONMENT  || 'prod';
  const isLocal = process.env.NODE_ENV === 'local';

  if (isLocal) {
    return {
      jwtSecret:     process.env.JWT_SECRET || 'local-dev-secret',
      userServiceUrl:    process.env.USER_SERVICE_URL    || 'http://localhost:3001',
      orderServiceUrl:   process.env.ORDER_SERVICE_URL   || 'http://localhost:3002',
      productServiceUrl: process.env.PRODUCT_SERVICE_URL || 'http://localhost:8000',
      analyticsServiceUrl: process.env.ANALYTICS_SERVICE_URL || 'http://localhost:8001',
      notificationServiceUrl: process.env.NOTIFICATION_SERVICE_URL || 'http://localhost:8002',
    };
  }

  const [jwtSecret, ssmParams] = await Promise.all([
    getSecret(`${PROJECT}/${ENV}/app/jwt-secret`),
    getSSMParams(`/${PROJECT}/${ENV}/config`),
  ]);

  return {
    jwtSecret: jwtSecret.value,
    userServiceUrl:         process.env.USER_SERVICE_URL         || `http://user-service.${PROJECT}-${ENV}.svc.cluster.local:3001`,
    orderServiceUrl:        process.env.ORDER_SERVICE_URL        || `http://order-service.${PROJECT}-${ENV}.svc.cluster.local:3002`,
    productServiceUrl:      process.env.PRODUCT_SERVICE_URL      || `http://product-service.${PROJECT}-${ENV}.svc.cluster.local:8000`,
    analyticsServiceUrl:    process.env.ANALYTICS_SERVICE_URL    || `http://analytics-service.${PROJECT}-${ENV}.svc.cluster.local:8001`,
    notificationServiceUrl: process.env.NOTIFICATION_SERVICE_URL || `http://notification-service.${PROJECT}-${ENV}.svc.cluster.local:8002`,
    logLevel: ssmParams['log-level'] || 'INFO',
  };
};

module.exports = { loadConfig, getSecret };
