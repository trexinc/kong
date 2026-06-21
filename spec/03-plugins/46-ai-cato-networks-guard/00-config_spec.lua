local PLUGIN_NAME = "ai-cato-networks-guard"


local validate do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()
  it("accepts a minimal config and applies defaults", function()
    local entity, err = validate({ api_key = "cato-tenant-token" })

    assert.is_nil(err)
    assert.equals("https://api.aim.security", entity.config.api_base)
    assert.is_true(entity.config.guard_request)
    assert.is_true(entity.config.guard_response)
    assert.equals("passthrough", entity.config.on_streaming)
    assert.is_false(entity.config.fail_open)
    assert.is_true(entity.config.https_verify)
    assert.equals(30000, entity.config.http_timeout)
  end)

  it("requires api_key", function()
    local ok, err = validate({ api_base = "https://api.aim.security" })

    assert.is_falsy(ok)
    assert.same({ api_key = "required field missing" }, err.config)
  end)

  it("accepts an explicit full config", function()
    local entity, err = validate({
      api_key = "cato-tenant-token",
      api_base = "http://localhost:9000",
      app_name = "my-gateway",
      guard_request = false,
      guard_response = true,
      on_streaming = "block",
      http_timeout = 5000,
      https_verify = false,
      fail_open = true,
      max_request_body_size = 4096,
    })

    assert.is_nil(err)
    assert.equals("my-gateway", entity.config.app_name)
    assert.is_false(entity.config.guard_request)
    assert.equals("block", entity.config.on_streaming)
    assert.is_true(entity.config.fail_open)
  end)

  it("rejects an unknown on_streaming value", function()
    local ok, err = validate({ api_key = "cato-tenant-token", on_streaming = "drop" })

    assert.is_falsy(ok)
    assert.is_not_nil(err.config.on_streaming)
  end)

  it("rejects a non-positive http_timeout", function()
    local ok, err = validate({ api_key = "cato-tenant-token", http_timeout = 0 })

    assert.is_falsy(ok)
    assert.is_not_nil(err.config.http_timeout)
  end)
end)
