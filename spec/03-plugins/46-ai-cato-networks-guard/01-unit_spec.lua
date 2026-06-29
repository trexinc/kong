local PLUGIN_NAME = "ai-cato-networks-guard"
local cato = require("kong.plugins." .. PLUGIN_NAME .. ".cato_client")


describe(PLUGIN_NAME .. ": (cato_client urls)", function()
  it("derives the REST analyze url", function()
    assert.equals("https://api.aim.security/fw/v1/analyze",
                  cato.analyze_url({ api_base = "https://api.aim.security" }))
  end)

  it("derives the wss stream url from an https base", function()
    assert.equals("wss://api.aim.security/fw/v1/analyze/stream",
                  cato.stream_url({ api_base = "https://api.aim.security" }))
  end)

  it("derives the ws stream url from an http base", function()
    assert.equals("ws://localhost:9000/fw/v1/analyze/stream",
                  cato.stream_url({ api_base = "http://localhost:9000" }))
  end)
end)


describe(PLUGIN_NAME .. ": (cato_client headers)", function()
  local conf = { api_key = "cato-t-k" }

  it("sets auth and hook headers", function()
    local h = cato.build_headers(conf, "pre_call", {})
    assert.equals("Bearer cato-t-k", h["Authorization"])
    assert.equals("pre_call", h["x-aim-litellm-hook"])
    assert.is_not_nil(h["x-cato-kong-version"])
  end)

  it("forwards present context headers and omits absent ones", function()
    local h = cato.build_headers(conf, "output", {
      call_id = "cid", user_email = "u@example.com", key_alias = "alias",
    })
    assert.equals("cid", h["x-cato-call-id"])
    assert.equals("u@example.com", h["x-cato-user-email"])
    assert.equals("alias", h["x-cato-gateway-key-alias"])
    assert.is_nil(h["x-cato-session-id"])
  end)
end)


describe(PLUGIN_NAME .. ": (cato_client interpret_request)", function()
  it("returns nil action when no required_action", function()
    assert.is_nil(cato.interpret_request({ required_action = nil }))
  end)

  it("treats monitor_action as allow", function()
    assert.equals("monitor_action",
                  cato.interpret_request({ required_action = { action_type = "monitor_action" } }))
  end)

  it("surfaces the detection message on block", function()
    local action, msg = cato.interpret_request({
      required_action = { action_type = "block_action", detection_message = "Jailbreak detected" },
    })
    assert.equals("block_action", action)
    assert.equals("Jailbreak detected", msg)
  end)

  it("returns redacted messages on anonymize", function()
    local action, _, redacted = cato.interpret_request({
      required_action = { action_type = "anonymize_action" },
      redacted_chat = { all_redacted_messages = {
        { role = "user", content = "my card is ****", extra = "ignored" },
      } },
    })
    assert.equals("anonymize_action", action)
    assert.same({ { role = "user", content = "my card is ****" } }, redacted)
  end)
end)


describe(PLUGIN_NAME .. ": (cato_client merge_redacted_content)", function()
  it("replaces content by index while preserving tool-call fields", function()
    local original = {
      { role = "user", content = "my SSN is 123-45-6789" },
      { role = "assistant", content = nil, tool_calls = {
        { id = "call_1", type = "function",
          ["function"] = { name = "lookup", arguments = "{\"ssn\":\"123-45-6789\"}" } },
      } },
      { role = "tool", tool_call_id = "call_1", name = "lookup", content = "result" },
    }
    local redacted = {
      { role = "user", content = "my SSN is [REDACTED]" },
      { role = "assistant", content = nil },
      { role = "tool", content = "result" },
    }

    local merged = cato.merge_redacted_content(original, redacted)

    assert.equals("my SSN is [REDACTED]", merged[1].content)
    -- tool_calls preserved on the assistant message
    assert.same(original[2].tool_calls, merged[2].tool_calls)
    -- tool_call_id / name preserved on the tool message
    assert.equals("call_1", merged[3].tool_call_id)
    assert.equals("lookup", merged[3].name)
  end)
end)


describe(PLUGIN_NAME .. ": (cato_client interpret_output)", function()
  it("returns the last redacted message content on anonymize", function()
    local action, _, redacted_output = cato.interpret_output({
      required_action = { action_type = "anonymize_action" },
      redacted_chat = { all_redacted_messages = {
        { role = "user", content = "first" },
        { role = "assistant", content = "redacted reply" },
      } },
    })
    assert.equals("anonymize_action", action)
    assert.equals("redacted reply", redacted_output)
  end)

  it("surfaces the detection message on block", function()
    local action, msg = cato.interpret_output({
      required_action = { action_type = "block_action", detection_message = "Leaked secret" },
    })
    assert.equals("block_action", action)
    assert.equals("Leaked secret", msg)
  end)
end)
