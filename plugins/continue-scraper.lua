local core = require("apisix.core")
local ngx = ngx
local string_find = string.find
local string_sub = string.sub

local plugin_name = "continue-scraper"

-- 插件配置架構
local schema = {
    type = "object",
    properties = {
        debug_logging = {
            type = "boolean",
            default = false
        },
        replacement_status = {
            type = "integer",
            minimum = 200,
            maximum = 599,
            default = 200
        },
        clean_response_body = {
            type = "boolean",
            default = true,
            description = "Clean response body from HTTP headers"
        },
        upstream_response_timeout = {
            type = "number",
            minimum = 100,
            default = 6000,  -- 默認6秒，單位毫秒
            description = "Timeout waiting for final response after modifying status"
        }
    }
}

local _M = {
    version = 0.2,
    priority = 18800,  -- 高優先級確保儘早處理
    name = plugin_name,
    schema = schema,
}

-- 日誌輔助函數
local function debug_log(conf, message, data)
    if not conf or not conf.debug_logging then
        return
    end
    
    if data then
        core.log.info(plugin_name .. ": " .. message .. " " .. core.json.encode(data))
    else
        core.log.info(plugin_name .. ": " .. message)
    end
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.init()
    core.log.notice(plugin_name .. " v0.2 initialized")
end

-- 重寫階段 - 設置上下文狀態
function _M.rewrite(conf, ctx)
    ctx.continue_scraper = {
        active = true,
        original_status = nil,
        need_body_cleanup = false
    }
    
    debug_log(conf, "Plugin activated for request", {
        uri = ctx.var.uri,
        method = ctx.var.request_method
    })
end

-- 頭部過濾器
function _M.header_filter(conf, ctx)
    if not ctx.continue_scraper or not ctx.continue_scraper.active then
        return
    end
    
    local current_status = ngx.status
    debug_log(conf, "Processing response", {status = current_status, uri = ctx.var.uri})
    
    -- 檢查是否為100 Continue
    if current_status == 100 then
        -- 記錄操作
        core.log.warn(plugin_name .. ": Detected 100 Continue, replacing with " 
                    .. conf.replacement_status .. " for: " 
                    .. ctx.var.request_method .. " " .. ctx.var.uri)
        
        -- 替換狀態碼
        ngx.status = conf.replacement_status

        -- 記錄開始時間用於超時檢測
        ctx.continue_scraper.response_start_time = ngx.now() * 1000
        
        -- 記錄原始狀態以便日誌
        ctx.continue_scraper.original_status = current_status
        ctx.continue_scraper.modified = true
        
        -- 標記需要清理響應體
        if conf.clean_response_body then
            ctx.continue_scraper.need_body_cleanup = true
        end
        
        -- 添加自定義響應頭，表明這是被修改的響應
        ngx.header["X-Original-Status"] = "100-Continue"
        ngx.header["X-Modified-By"] = plugin_name .. "-v0.2"
        
        debug_log(conf, "Status replaced", {
            from = current_status,
            to = conf.replacement_status
        })
    end
end

-- 正則函數：查找響應體中的 HTTP 頭和實際內容的分隔點
local function find_body_start(body)
    if not body or body == "" then
        return nil
    end
    
    -- 查找第一個空行（HTTP headers 和 body 之間的分隔）
    local pattern = "\r\n\r\n"
    local pos = string_find(body, pattern)
    if pos then
        -- 返回 body 實際開始的位置（空行之後）
        return pos + 4
    end
    
    -- 嘗試另一種分隔模式
    pattern = "\n\n"
    pos = string_find(body, pattern)
    if pos then
        return pos + 2
    end
    
    -- 如果沒找到分隔符，返回 nil
    return nil
end

-- 清理響應體，移除 HTTP 頭部分
local function clean_response_body(body)
    if not body or body == "" then
        return body
    end

    -- 嘗試識別這是否是HTTP響應
    if not string_find(body, "^HTTP/[%d%.]+%s%d%d%d") then
        -- 如果不像是HTTP響應，直接返回原始內容
        return body
    end
    
    -- 嘗試找到響應體的實際開始位置
    local body_start = find_body_start(body)
    
    -- 如果找到分隔點，只返回實際的響應體部分
    if body_start then
        return string_sub(body, body_start)
    end
    
    -- 如果無法確定分隔，返回原始內容
    return body
end

-- 響應體過濾
function _M.body_filter(conf, ctx)
    if not ctx or not ctx.continue_scraper or not ctx.continue_scraper.active then
        return
    end
    
    -- 只有當我們需要清理響應體時才處理
    if not ctx.continue_scraper.need_body_cleanup or not conf.clean_response_body then
        return
    end

    if ctx.continue_scraper.response_start_time then
        local elapsed = ngx.now() * 1000 - ctx.continue_scraper.response_start_time
        if elapsed > conf.upstream_response_timeout then
            core.log.error(plugin_name .. ": Timeout waiting for response after " .. elapsed .. "ms")
            
            
            ctx.continue_scraper.body_chunks = nil --清理Chunk
            ngx.arg[1] = '{"error":"Response timeout","code":"GATEWAY_TIMEOUT"}' -- 返回錯誤
            ngx.arg[2] = true  -- 標記為最後一塊
            ngx.status = 504  -- 設置網關超時狀態
            return
        end
    end
    
    -- 獲取當前塊的響應體
    local chunk = ngx.arg[1]
    local is_last_chunk = ngx.arg[2]
    
    -- 初始化響應體緩存（如果尚未初始化）
    if not ctx.continue_scraper.body_chunks then
        ctx.continue_scraper.body_chunks = {}
    end
    
    -- 處理響應體塊
    if chunk and chunk ~= "" then
        table.insert(ctx.continue_scraper.body_chunks, chunk)
        -- 暫時不輸出任何內容
        ngx.arg[1] = nil
    end
    
    -- 當遇到最後一個塊時，處理整個響應體
    if is_last_chunk then
        local full_body = table.concat(ctx.continue_scraper.body_chunks)
        local clean_body = clean_response_body(full_body)
        
        -- 日誌記錄清理前後的長度變化，用於調試
        if conf.debug_logging then
            debug_log(conf, "Body cleaned", {
                original_length = #full_body,
                cleaned_length = #clean_body,
                diff = #full_body - #clean_body
            })
        end
        
        -- 輸出清理後的響應體
        ngx.arg[1] = clean_body
        ngx.arg[2] = true
        
        -- 更新內容長度頭
        if #clean_body ~= #full_body then
            ngx.header.content_length = #clean_body
        end
    end
end

-- 日誌階段
function _M.log(conf, ctx)
    if not ctx.continue_scraper or not ctx.continue_scraper.active then
        return
    end
    
    if ctx.continue_scraper.modified then
        debug_log(conf, "Response was modified", {
            original_status = ctx.continue_scraper.original_status,
            final_status = ngx.status,
            uri = ctx.var.uri,
            body_cleaned = ctx.continue_scraper.need_body_cleanup
        })
    else
        debug_log(conf, "Request completed without modification", {
            status = ngx.status,
            uri = ctx.var.uri
        })
    end
end

return _M
