--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local apisix_plugin = require("apisix.plugin")
local tab_insert = table.insert
local ipairs = ipairs
local pairs = pairs
local redis_schema = require("apisix.utils.redis-schema")
local policy_to_additional_properties = redis_schema.schema
local get_phase = ngx.get_phase

local limit_redis_cluster_new
local limit_redis_new
local limit_local_new
do
    local local_src = "apisix.plugins.limit-count.limit-count-local"
    limit_local_new = require(local_src).new

    local redis_src = "apisix.plugins.limit-count.limit-count-redis"
    limit_redis_new = require(redis_src).new

    local cluster_src = "apisix.plugins.limit-count.limit-count-redis-cluster"
    limit_redis_cluster_new = require(cluster_src).new
end
local lrucache = core.lrucache.new({
    type = 'plugin', serial_creating = true,
})
local group_conf_lru = core.lrucache.new({
    type = 'plugin',
})

local metadata_defaults = {
    limit_header = "X-RateLimit-Limit",
    remaining_header = "X-RateLimit-Remaining",
    reset_header = "X-RateLimit-Reset",
}

local metadata_schema = {
    type = "object",
    properties = {
        limit_header = {
            type = "string",
            default = metadata_defaults.limit_header,
        },
        remaining_header = {
            type = "string",
            default = metadata_defaults.remaining_header,
        },
        reset_header = {
            type = "string",
            default = metadata_defaults.reset_header,
        },
    },
}

local schema = {
    type = "object",
    properties = {
        count = {type = "integer", exclusiveMinimum = 0},
        time_window = {type = "integer",  exclusiveMinimum = 0},
        group = {type = "string"},
        key = {type = "string", default = "remote_addr"},
        key_type = {type = "string",
            enum = {"var", "var_combination", "constant"},
            default = "var",
        },
        rejected_code = {
            type = "integer", minimum = 200, maximum = 599, default = 503
        },
        rejected_msg = {
            type = "string", minLength = 1
        },
        policy = {
            type = "string",
            enum = {"local", "redis", "redis-cluster"},
            default = "local",
        },
        allow_degradation = {type = "boolean", default = false},
        show_limit_quota_header = {type = "boolean", default = true}
    },
    required = {"count", "time_window"},
    ["if"] = {
        properties = {
            policy = {
                enum = {"redis"},
            },
        },
    },
    ["then"] = policy_to_additional_properties.redis,
    ["else"] = {
        ["if"] = {
            properties = {
                policy = {
                    enum = {"redis-cluster"},
                },
            },
        },
        ["then"] = policy_to_additional_properties["redis-cluster"],
    }
}

local schema_copy = core.table.deepcopy(schema)

local _M = {
    schema = schema,
    metadata_schema = metadata_schema,
}


local function group_conf(conf)
    return conf
end



function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if conf.group then
        -- means that call by some plugin not support
        if conf._vid then
            return false, "group is not supported"
        end

        local fields = {}
        -- When the goup field is configured,
        -- we will use schema_copy to get the whitelist of properties,
        -- so that we can avoid getting injected properties.
        for k in pairs(schema_copy.properties) do
            tab_insert(fields, k)
        end
        local extra = policy_to_additional_properties[conf.policy]
        if extra then
            for k in pairs(extra.properties) do
                tab_insert(fields, k)
            end
        end

        local prev_conf = group_conf_lru(conf.group, "", group_conf, conf)

        for _, field in ipairs(fields) do
            if not core.table.deep_eq(prev_conf[field], conf[field]) then
                core.log.error("previous limit-conn group ", prev_conf.group,
                            " conf: ", core.json.encode(prev_conf))
                core.log.error("current limit-conn group ", conf.group,
                            " conf: ", core.json.encode(conf))
                return false, "group conf mismatched"
            end
        end
    end

    return true
end


local function create_limit_obj(conf, plugin_name)
    core.log.info("create new " .. plugin_name .. " plugin instance")

    if not conf.policy or conf.policy == "local" then
        return limit_local_new("plugin-" .. plugin_name, conf.count,
                               conf.time_window)
    end

    if conf.policy == "redis" then
        return limit_redis_new("plugin-" .. plugin_name,
                               conf.count, conf.time_window, conf)
    end

    if conf.policy == "redis-cluster" then
        return limit_redis_cluster_new("plugin-" .. plugin_name, conf.count,
                                       conf.time_window, conf)
    end

    return nil
end


local function gen_limit_key(conf, ctx, key)
    if conf.group then
        return conf.group .. ':' .. key
    end

    -- here we add a separator ':' to mark the boundary of the prefix and the key itself
    -- Here we use plugin-level conf version to prevent the counter from being resetting
    -- because of the change elsewhere.
    -- A route which reuses a previous route's ID will inherits its counter.
    local conf_type = ctx.conf_type_without_consumer or ctx.conf_type
    local conf_id = ctx.conf_id_without_consumer or ctx.conf_id
    local new_key = conf_type .. conf_id .. ':' .. apisix_plugin.conf_version(conf)
                    .. ':' .. key
    if conf._vid then
        -- conf has _vid means it's from workflow plugin, add _vid to the key
        -- so that the counter is unique per action.
        return new_key .. ':' .. conf._vid
    end

    return new_key
end


local function gen_limit_obj(conf, ctx, plugin_name)
    if conf.group then
        return lrucache(conf.group, "", create_limit_obj, conf, plugin_name)
    end

    local extra_key
    if conf._vid then
        extra_key = conf.policy .. '#' .. conf._vid
    else
        extra_key = conf.policy
    end

    return core.lrucache.plugin_ctx(lrucache, ctx, extra_key, create_limit_obj, conf, plugin_name)
end

function _M.rate_limit(conf, ctx, name, cost, dry_run)
    core.log.info("ver: ", ctx.conf_version)
    core.log.info("conf: ", core.json.delay_encode(conf, true))

    local lim, err = gen_limit_obj(conf, ctx, name)

    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        if conf.allow_degradation then
            return
        end
        return 500
    end

    local conf_key = conf.key
    local key
    if conf.key_type == "var_combination" then
        local err, n_resolved
        key, err, n_resolved = core.utils.resolve_var(conf_key, ctx.var)
        if err then
            core.log.error("could not resolve vars in ", conf_key, " error: ", err)
        end

        if n_resolved == 0 then
            key = nil
        end
    elseif conf.key_type == "constant" then
        key = conf_key
    else
        key = ctx.var[conf_key]
    end

    if key == nil then
        core.log.info("The value of the configured key is empty, use client IP instead")
        -- When the value of key is empty, use client IP instead
        key = ctx.var["remote_addr"]
    end

    key = gen_limit_key(conf, ctx, key)
    core.log.info("limit key: ", key)

    local delay, remaining, reset
    if not conf.policy or conf.policy == "local" then
        delay, remaining, reset = lim:incoming(key, not dry_run, conf, cost)
    else
        delay, remaining, reset = lim:incoming(key, cost)
    end

    local metadata = apisix_plugin.plugin_metadata("limit-count")
    if metadata then
        metadata = metadata.value
    else
        metadata = metadata_defaults
    end
    core.log.info("limit-count plugin-metadata: ", core.json.delay_encode(metadata))

    local set_limit_headers = {
        limit_header = conf.limit_header or metadata.limit_header,
        remaining_header = conf.remaining_header or metadata.remaining_header,
        reset_header = conf.reset_header or metadata.reset_header,
    }
    local phase = get_phase()
    local set_header = phase ~= "log"

    if not delay then
        local err = remaining
        if err == "rejected" then
            -- show count limit header when rejected
            if conf.show_limit_quota_header and set_header then
                core.response.set_header(set_limit_headers.limit_header, conf.count,
                set_limit_headers.remaining_header, 0,
                set_limit_headers.reset_header, reset)
            end

            if conf.rejected_msg then
                return conf.rejected_code, { error_msg = conf.rejected_msg }
            end
            return conf.rejected_code
        end

        core.log.error("failed to limit count: ", err)
        if conf.allow_degradation then
            return
        end
        return 500, {error_msg = "failed to limit count"}
    end

    if conf.show_limit_quota_header and set_header then
        core.response.set_header(set_limit_headers.limit_header, conf.count,
            set_limit_headers.remaining_header, remaining,
            set_limit_headers.reset_header, reset)
    end
end


return _M
