# frozen_string_literal: true

module Mistri
  module MCP
    # A client of the official MCP Ruby SDK, the mcp gem, in the shape the
    # bridge takes. The host builds and connects the SDK's client, and closes
    # it:
    #
    #   sdk = ::MCP::Client.new(transport: transport)
    #   sdk.connect(client_info: { name: "YourApp", version: "1.0" })
    #   tools = Mistri::MCP.tools(Mistri::MCP::SDKClient.new(sdk), prefix: "files")
    #
    # Mistri does not depend on the SDK: nothing here names one of its
    # constants, so the wrapped object only has to answer as its client does.
    class SDKClient
      def initialize(client)
        @client = client
      end

      def tools
        @client.tools.map do |tool|
          { "name" => tool.name, "title" => tool.title, "description" => tool.description,
            "inputSchema" => tool.input_schema, "annotations" => tool.annotations }.compact
        end
      end

      # The SDK returns the whole JSON-RPC response, and raises for an error
      # the server answered with.
      def call_tool(name, arguments = {})
        response = @client.call_tool(name: name, arguments: arguments)
        result = response["result"] if response.is_a?(Hash)
        return result if result.is_a?(Hash)

        raise Error, "tools/call returned a malformed result"
      end

      def instructions = @client.instructions

      def resources?
        declared = @client.server_capabilities
        declared.is_a?(Hash) && declared.key?("resources")
      end

      def read_resource(uri) = @client.read_resource(uri: uri)
    end
  end
end
