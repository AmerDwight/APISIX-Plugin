# Apache APISIX 插件說明文件

## 插件概述

本文件說明兩個自定義 APISIX 插件的用途與使用方法：

1. **continue-scraper** - HTTP 100 Continue 響應處理插件
2. **request-verify** - 請求驗證插件

---

## 1. continue-scraper 插件

### 用途
此插件主要用於處理 HTTP 100 Continue 響應狀態碼的問題。當上游服務回傳 100 Continue 狀態碼時，插件會：
- 將 100 狀態碼替換為指定的狀態碼（預設為 200）
- 清理響應體中的 HTTP 頭部信息
- 提供超時處理機制
- 記錄詳細的調試日誌

### 配置參數

```json
{
  "debug_logging": false,           // 是否啟用調試日誌
  "replacement_status": 200,        // 替換 100 Continue 的狀態碼
  "clean_response_body": true,      // 是否清理響應體中的 HTTP 頭
  "upstream_response_timeout": 6000 // 上游響應超時時間（毫秒）
}
```

### 使用方法

#### 1. 啟用插件
```bash
curl -X PUT "http://127.0.0.1:9080/apisix/admin/routes/1" \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/api/*",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "httpbin.org:80": 1
      }
    },
    "plugins": {
      "continue-scraper": {
        "debug_logging": true,
        "replacement_status": 200,
        "clean_response_body": true,
        "upstream_response_timeout": 5000
      }
    }
  }'
```

### 工作流程
1. **rewrite 階段**：初始化插件上下文
2. **header_filter 階段**：檢測並替換 100 Continue 狀態碼
3. **body_filter 階段**：處理和清理響應體
4. **log 階段**：記錄處理結果

---

## 2. request-verify 插件

### 用途
此插件用於驗證請求中的特定字段值，支援多種數據源：
- XML 格式的請求體
- JSON 格式的請求體
- URL 查詢參數
- HTTP 頭部

### 配置參數

```json
{
  "verify_source": "json",        // 驗證來源：xml|json|query_parameter|header
  "verify_field": "user_id",      // 要驗證的字段名稱
  "verify_value": "12345"         // 期望的字段值
}
```

### 使用方法

#### 1. JSON 請求體驗證
```bash
curl -X PUT "http://127.0.0.1:9080/apisix/admin/routes/1" \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -d '{
    "uri": "/api/users",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "backend.example.com:80": 1
      }
    },
    "plugins": {
      "request-verify": {
        "verify_source": "json",
        "verify_field": "user_type",
        "verify_value": "premium"
      }
    }
  }'
```

發送請求：
```bash
curl -X POST "http://127.0.0.1:9080/api/users" \
  -H "Content-Type: application/json" \
  -d '{"user_type": "premium", "name": "John"}'
```

#### 2. XML 請求體驗證
```json
{
  "request-verify": {
    "verify_source": "xml",
    "verify_field": "user_id",
    "verify_value": "12345"
  }
}
```

發送請求：
```bash
curl -X POST "http://127.0.0.1:9080/api/xml-endpoint" \
  -H "Content-Type: application/xml" \
  -d '<request><user_id>12345</user_id><action>create</action></request>'
```

#### 3. 查詢參數驗證
```json
{
  "request-verify": {
    "verify_source": "query_parameter",
    "verify_field": "token",
    "verify_value": "secret123"
  }
}
```

發送請求：
```bash
curl "http://127.0.0.1:9080/api/data?token=secret123&page=1"
```

#### 4. HTTP 頭部驗證
```json
{
  "request-verify": {
    "verify_source": "header",
    "verify_field": "X-Client-Version",
    "verify_value": "v2.0"
  }
}
```

發送請求：
```bash
curl -X GET "http://127.0.0.1:9080/api/endpoint" \
  -H "X-Client-Version: v2.0"
```

### 錯誤響應

當驗證失敗時，插件會返回相應的錯誤：

**字段不存在（401）**：
```json
{
  "message": "Invalid Request, can't find value in request: type = json, field = user_type"
}
```

**字段值不匹配（401）**：
```json
{
  "message": "Invalid Request, please check header or content: user_type match with: premium"
}
```

**配置錯誤（506）**：
```json
{
  "message": "Invalid setup by service provider, please go check with administrator."
}
```

### 工作流程
1. **check_schema**：驗證插件配置
2. **rewrite 階段**：根據配置的來源提取並驗證字段值
3. **log 階段**：記錄請求和配置信息（用於調試）

---
