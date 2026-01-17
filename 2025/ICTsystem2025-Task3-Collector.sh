#!/bin/bash

# ファイル名例: ICTsystem2025-Task3-Collector.sh
# Usage: ./ICTsystem2025-Task3-Collector.sh STUDENT_ID TABLE_NAME LAMBDA_NAME REST_API_NAME

if [ $# -ne 4 ]; then
  echo "Usage: $0 STUDENT_ID TABLE_NAME LAMBDA_NAME REST_API_NAME" 1>&2
  exit 1
fi

STUDENT_ID="$1"
TABLE_NAME="$2"
LAMBDA_NAME="$3"
REST_API_NAME="$4"

echo "Collecting Task3 evidence..."

# 一時ファイル名
TMP_DDB="tmp-dynamo.json"
TMP_LAMBDA_META="tmp-lambda-meta.json"
TMP_APIS="tmp-apigw-apis.json"
TMP_RES="tmp-apigw-resources.json"
TMP_STAGES="tmp-apigw-stages.json"

########################################
# 1. DynamoDB テーブルの証跡
########################################
aws dynamodb describe-table \
  --table-name "${TABLE_NAME}" \
  --output json > "${TMP_DDB}" 2> /dev/null || true

########################################
# 2. Lambda 関数の証跡（メタ情報＋コード取得）
########################################
LAMBDA_CODE_TEXT=""
if aws lambda get-function \
      --function-name "${LAMBDA_NAME}" \
      --output json > "${TMP_LAMBDA_META}" 2> /dev/null; then

  # Code.Location からzipをダウンロードして展開
  CODE_URL=$(jq -r '.Code.Location' "${TMP_LAMBDA_META}")
  if [ -n "${CODE_URL}" ] && [ "${CODE_URL}" != "null" ]; then
    mkdir -p tmp_lambda_code
    curl -s "${CODE_URL}" -o tmp_lambda_code/code.zip
    if unzip -o -q tmp_lambda_code/code.zip -d tmp_lambda_code/extracted 2> /dev/null; then
      if [ -f tmp_lambda_code/extracted/lambda_function.py ]; then
        LAMBDA_CODE_TEXT=$(sed 's/\r$//' tmp_lambda_code/extracted/lambda_function.py)
      fi
    fi
  fi
fi

########################################
# 3. API Gateway（REST API）の証跡
########################################
REST_API_ID=""
if aws apigateway get-rest-apis \
      --output json > "${TMP_APIS}" 2> /dev/null; then
  REST_API_ID=$(
    jq -r --arg name "${REST_API_NAME}" '.items[] | select(.name == $name) | .id' "${TMP_APIS}"
  )
fi

if [ -n "${REST_API_ID}" ]; then
  # 対象APIのみ抽出
  jq --arg name "${REST_API_NAME}" \
     '.items[] | select(.name == $name)' \
     "${TMP_APIS}" > "${TMP_APIS}.filtered" 2> /dev/null || true
  mv "${TMP_APIS}.filtered" "${TMP_APIS}" 2> /dev/null || true

  # リソース
  aws apigateway get-resources \
    --rest-api-id "${REST_API_ID}" \
    --embed methods \
    --output json > "${TMP_RES}" 2> /dev/null || true

  # ステージ
  aws apigateway get-stages \
    --rest-api-id "${REST_API_ID}" \
    --output json > "${TMP_STAGES}" 2> /dev/null || true
fi

########################################
# 4. jq で1つの JSON に統合（Lambdaコードも埋め込む）
########################################

OUTPUT_FILE="ICTsystem2025-Task3-${STUDENT_ID}.json"
JST_NOW=$(TZ=Asia/Tokyo date --iso-8601=seconds)

jq -n \
  --arg generatedAt "${JST_NOW}" \
  --arg tableName   "${TABLE_NAME}" \
  --arg lambdaName  "${LAMBDA_NAME}" \
  --arg restApiName "${REST_API_NAME}" \
  --arg lambdaCode  "${LAMBDA_CODE_TEXT}" \
  --slurpfile dynamo  "${TMP_DDB}" \
  --slurpfile lambda  "${TMP_LAMBDA_META}" \
  --slurpfile apis    "${TMP_APIS}" \
  --slurpfile res     "${TMP_RES}" \
  --slurpfile stages  "${TMP_STAGES}" \
  '{
    generatedAt: $generatedAt,
    taskNumber: 3,
    studentId: "'"${STUDENT_ID}"'",
    tableName: $tableName,
    lambdaName: $lambdaName,
    restApiName: $restApiName,
    dynamodb:  $dynamo[0],
    lambda:    $lambda[0],
    lambdaSource: $lambdaCode,
    apigwApis: $apis[0],
    apigwResources: $res[0],
    apigwStages: $stages[0]
  }' > "${OUTPUT_FILE}"

rm -rf tmp_lambda_code
rm -f "${TMP_DDB}" "${TMP_LAMBDA_META}" "${TMP_APIS}" "${TMP_RES}" "${TMP_STAGES}"

echo "Evidence JSON generated: ${OUTPUT_FILE}"
