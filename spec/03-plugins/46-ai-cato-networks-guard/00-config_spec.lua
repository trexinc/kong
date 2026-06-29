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
    assert.equals("BOTH", entity.config.guarding_mode)
    assert.is_true(entity.config.allow_masking)
    assert.is_true(entity.config.stop_on_error)
    assert.is_true(entity.config.https_verify)
    assert.equals(30000, entity.config.http_timeout)
    assert.equals(100, entity.config.response_buffer_size)
  end)

  it("requires api_key", function()
    local ok, err = validate({ api_base = "https://api.aim.security" })

    assert.is_falsy(ok)
    assert.same({ api_key = "required field missing" }, err.config)
  end)

  it("rejects an unknown guarding_mode", function()
    local ok, err = validate({ api_key = "k", guarding_mode = "SIDEWAYS" })

    assert.is_falsy(ok)
    assert.is_not_nil(err.config.guarding_mode)
  end)

  it("accepts an explicit full config", function()
    local entity, err = validate({
      api_key = "cato-tenant-token",
      api_base = "http://localhost:9000",
      app_name = "my-gateway",
      guarding_mode = "OUTPUT",
      allow_masking = false,
      stop_on_error = false,
      response_buffer_size = 256,
      http_timeout = 5000,
      https_verify = false,
      log_blocked_content = true,
    })

    assert.is_nil(err)
    assert.equals("my-gateway", entity.config.app_name)
    assert.equals("OUTPUT", entity.config.guarding_mode)
    assert.is_false(entity.config.allow_masking)
  end)
end)
