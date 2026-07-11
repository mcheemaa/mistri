# frozen_string_literal: true

require_relative "test_helper"

# Task schemas use native constrained decoding only when a provider can carry
# the same contract; prompt and local validation cover every fallback.
class TestProviderSchemaCapabilities < Minitest::Test
  PROVIDERS = {
    openai: -> { Mistri::Providers::OpenAI.new(api_key: "test") },
    anthropic: -> { Mistri::Providers::Anthropic.new(api_key: "test") },
    gemini: -> { Mistri::Providers::Gemini.new(api_key: "test") }
  }.freeze

  def test_provider_native_schema_capability_matrix
    object = {
      type: "object", properties: { value: { type: "string" } }, required: ["value"]
    }
    scalar = { type: "string", enum: %w[low high] }
    tuple = {
      type: "array", prefixItems: [{ type: "string" }, { type: "integer" }], items: false
    }
    titled = { type: "string", title: "Day", format: "date" }
    nullable = { type: %w[string null] }

    assert_capabilities object, openai: true, anthropic: true, gemini: true
    assert_capabilities scalar, openai: false, anthropic: true, gemini: true
    assert_capabilities tuple, openai: false, anthropic: false, gemini: true
    assert_capabilities titled, openai: false, anthropic: false, gemini: true
    assert_capabilities nullable, openai: false, anthropic: false, gemini: false
  end

  def test_all_providers_accept_homogeneous_primitive_and_object_arrays
    string_array = {
      type: "object",
      properties: { values: { type: "array", items: { type: "string" } } },
      required: ["values"]
    }
    object_array = {
      type: "object",
      properties: {
        values: {
          type: "array",
          items: {
            type: "object", properties: { value: { type: "string" } }, required: ["value"]
          }
        }
      },
      required: ["values"]
    }

    assert_capabilities string_array, openai: true, anthropic: true, gemini: true
    assert_capabilities object_array, openai: true, anthropic: true, gemini: true
  end

  def test_explicit_provider_complexity_limits_fall_back_locally
    refute_nil native(:openai, nested_objects(10))
    assert_nil native(:openai, nested_objects(11))

    refute_nil raw_capability(:openai, wide_object(5000))
    assert_nil raw_capability(:openai, wide_object(5001))

    refute_nil native(:openai, enum_schema((1..1000).map(&:to_s)))
    assert_nil native(:openai, enum_schema((1..1001).map(&:to_s)))

    refute_nil native(:openai, enum_schema(enum_strings(251, 15_000)))
    assert_nil native(:openai, enum_schema(enum_strings(251, 15_001)))

    refute_nil native(:openai, named_property(120_000))
    assert_nil native(:openai, named_property(120_001))

    refute_nil native(:anthropic, optional_properties(24))
    assert_nil native(:anthropic, optional_properties(25))
  end

  def test_unknown_models_keep_structured_output_validation_local
    canonical = Mistri::Schema.task_plan(
      { type: "object", properties: { value: { type: "string" } }, required: ["value"] }
    ).schema
    providers = [
      Mistri::Providers::OpenAI.new(api_key: "test", model: "gpt-future"),
      Mistri::Providers::Anthropic.new(api_key: "test", model: "claude-future"),
      Mistri::Providers::Gemini.new(api_key: "test", model: "gemini-future")
    ]

    providers.each { |provider| assert_nil provider.native_output_schema(canonical) }
  ensure
    providers&.each(&:close)
  end

  def test_openai_falls_back_instead_of_making_optional_fields_required
    optional = {
      type: "object", properties: { note: { type: "string" } }, required: []
    }

    assert_capabilities optional, openai: false, anthropic: true, gemini: true
  end

  def test_gemini_keeps_boolean_tuple_members
    schema = {
      type: "array", prefixItems: [true, { type: "boolean" }], items: false
    }

    assert_capabilities schema, openai: false, anthropic: false, gemini: true
  end

  def test_gemini_uses_only_its_documented_type_specific_keywords
    assert_capabilities({ type: "string", format: "date" },
                        openai: false, anthropic: false, gemini: true)
    assert_capabilities({ type: "string", format: "uuid" },
                        openai: false, anthropic: false, gemini: false)
    assert_capabilities({ type: "integer", format: "date" },
                        openai: false, anthropic: false, gemini: false)
    assert_capabilities({ type: "boolean", enum: [true, false] },
                        openai: false, anthropic: true, gemini: false)
  end

  def test_gemini_enum_members_match_the_declared_json_type
    assert_capabilities({ type: "string", enum: ["valid", 1] },
                        openai: false, anthropic: true, gemini: false)
    assert_capabilities({ type: "number", enum: [1, 2.5] },
                        openai: false, anthropic: true, gemini: true)
    assert_capabilities({ type: "integer", enum: [1, 2.0] },
                        openai: false, anthropic: true, gemini: true)
    assert_capabilities({ type: "integer", enum: [1, 2.5] },
                        openai: false, anthropic: true, gemini: false)
  end

  def test_native_objects_require_only_declared_properties
    schema = {
      type: "object", properties: { known: { type: "string" } },
      required: %w[known missing]
    }

    assert_capabilities schema, openai: false, anthropic: false, gemini: false
  end

  def test_nil_fallback_is_not_restricted_again_by_provider_request_builders
    history = [Mistri::Message.user("hello")]
    providers = {
      openai: PROVIDERS.fetch(:openai).call,
      anthropic: PROVIDERS.fetch(:anthropic).call,
      gemini: PROVIDERS.fetch(:gemini).call
    }

    openai = providers[:openai].send(:build_body, "gpt-5.6", history, nil, [],
                                     output_schema: nil)
    anthropic = providers[:anthropic].send(
      :build_body, "claude-haiku-4-5-20251001", history, nil, [], output_schema: nil
    )
    gemini = providers[:gemini].send(:build_body, history, nil, [], output_schema: nil)

    refute openai.key?(:text)
    refute anthropic.key?(:output_config)
    refute gemini.fetch(:generationConfig).key?(:responseJsonSchema)
  end

  def test_gemini_with_tools_keeps_task_validation_local
    provider = PROVIDERS.fetch(:gemini).call
    plan = Mistri::Schema.task_plan(
      { type: "object", properties: { answer: { type: "string" } }, required: ["answer"] }
    )
    schema = provider.native_output_schema(plan.schema)
    tool = {
      name: "lookup", description: "Looks up.",
      input_schema: { "type" => "object", "properties" => {} }
    }

    body = provider.send(:build_body, [Mistri::Message.user("hello")], nil, [tool],
                         output_schema: schema)

    refute body.fetch(:generationConfig).key?(:responseJsonSchema)
  end

  private

  def nested_objects(levels)
    levels.times.reduce({ type: "string" }) do |child, _|
      { type: "object", properties: { value: child }, required: ["value"] }
    end
  end

  def wide_object(count)
    properties = count.times.to_h { |index| ["p#{index}", { "type" => "string" }] }
    { "type" => "object", "properties" => properties,
      "required" => properties.keys, "additionalProperties" => false }
  end

  def enum_schema(values)
    { type: "object", properties: { value: { type: "string", enum: values } },
      required: ["value"] }
  end

  def enum_strings(count, total)
    base, extra = total.divmod(count)
    Array.new(count) do |index|
      length = base + (index < extra ? 1 : 0)
      prefix = index.to_s
      "#{prefix}#{"x" * (length - prefix.length)}"
    end
  end

  def named_property(length)
    name = "x" * length
    { type: "object", properties: { name => { type: "string" } }, required: [name] }
  end

  def optional_properties(count)
    { type: "object",
      properties: count.times.to_h { |index| ["field_#{index}", { type: "string" }] },
      required: [] }
  end

  def raw_capability(name, schema)
    capabilities = Mistri::Providers.const_get(:SchemaCapabilities, false)
    capabilities.derive(schema, name)
  end

  def native(name, schema)
    canonical = Mistri::Schema.task_plan(schema).schema
    PROVIDERS.fetch(name).call.native_output_schema(canonical)
  end

  def assert_capabilities(schema, expectations)
    canonical = Mistri::Schema.task_plan(schema).schema
    expectations.each do |name, supported|
      native = PROVIDERS.fetch(name).call.native_output_schema(canonical)
      if supported
        assert_same canonical, native, name
        assert_predicate native, :frozen?, name
      else
        assert_nil native, name
      end
    end
  end
end
