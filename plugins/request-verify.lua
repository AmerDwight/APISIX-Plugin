-- Introduce the necessary modules/libraries we need for this plugin 
local core = require("apisix.core")
local cjson = require("cjson.safe")

-- Declare the plugin's name
local plugin_name = "request-verify"

-- Declare the plugin error
local target_value_not_found_message_format = "Invalid Request, can't find value in request: type = %s, field = %s"

-- Define the plugin schema format
local schema = {
    type = "object",
    properties = {
        verify_source = {
            type = "string" -- The verify_source indicates plugin to check
        },
        verify_field = {
            type = "string"
        },
        verify_value = {
            type = "string"
        },
    },
    required = {"verify_source","verify_field","verify_value"} -- The path is a required field
}


-- Define the plugin with its version, priority, name, and schema
local _M = {
    version = 1.0,
    priority = 2501,
    type = 'auth',
    name = plugin_name,
    schema = schema
}

local function extractXmlValue(fieldName, ctx)
    -- Search by regular expression
    local pattern = "<" .. fieldName .. ">(.-)</" .. fieldName .. ">"
    local value = (core.request.get_body(nil,ctx)):match(pattern)
    if value then
        -- Eliminate blank
        local cleanedValue = value:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
        return cleanedValue
    else
        return nil
    end
end

local function extractJsonValue(fieldName, ctx)
    -- Parse the JSON string into a Lua table
    local data, err = cjson.decode(core.request.get_body(nil,ctx))
    if not data then
        -- If there is an error in parsing, return nil and the error message
        return nil
    end

    -- Navigate and extract the value for the specified field
    local value = data[fieldName]
    if value then
        -- Return the value if it exists
        return value
    else
        -- If the field does not exist in the JSON, return nil
        return nil
    end
end

local function extractQureyParameterValue(fieldName, ctx)
    local uri_args = core.request.get_uri_args(ctx) or {}
    local value = uri_args[fieldName]
    if value then 
        return value
    else
        return nil
    end
end

local function extractHeaderValue(fieldName, ctx)
    local value = core.request.header(ctx, fieldName)
    if value then 
        return value
    else
        return nil
    end
end

-- Function to check if the plugin configuration is correct
function _M.check_schema(conf )
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local pass_verify = false
    local source = conf.verify_source
    local field = conf.verify_field
    local value = conf.verify_value

    if source == "xml" then
        local on_check_value  = extractXmlValue(field, ctx)
        if on_check_value then
            pass_verify = (on_check_value == value)
        else
            return 401, {message = string.format(target_value_not_found_message_format,source,field) }
        end

    elseif source == "json" then
        local on_check_value  = extractJsonValue(field, ctx)
        if on_check_value then
            pass_verify = (on_check_value == value)
        else
            return 401, {message = string.format(target_value_not_found_message_format,source,field) }
        end
    elseif source == "query_parameter" then
        local on_check_value = extractQureyParameterValue(field,ctx)
        if on_check_value then
            pass_verify = (on_check_value == value)
        else
            return 401, {message = string.format(target_value_not_found_message_format,source,field) }
        end
    elseif source == "header" then
        local on_check_value = extractHeaderValue(field,ctx)
        if on_check_value then
            pass_verify = (on_check_value == value)
        else
            return 401, {message = string.format(target_value_not_found_message_format,source,field) }
        end
    else
        return 506, {message = "Invalid setup by service provider, please go check with administrator."}
    end


    if not pass_verify then
        return 401, {message = "Invalid Request, please check header or content: ".. field .. " match with: " .. value }
    end
end

-- Function to be called during the log phase
function _M.log(conf, ctx)
    -- Log the plugin configuration and the request context
    core.log.warn("request-verify log: -------------------")
    core.log.warn("conf: ", core.json.encode(conf))
    core.log.warn("ctx: ", core.json.encode(ctx, true))
    core.log.warn("---------------------------------------")
end

-- Return the plugin so it can be used by APISIX
return _M
