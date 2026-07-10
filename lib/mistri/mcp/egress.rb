# frozen_string_literal: true

require "ipaddr"
require "socket"
require "timeout"
require "uri"

module Mistri
  module MCP
    # Resolves untrusted MCP URLs onto globally reachable addresses and pins
    # that decision to the eventual connection. A host may narrowly approve a
    # non-public address, but cannot bypass URL shape or plaintext rules.
    module Egress
      Target = Data.define(:uri, :address)
      NAT64_WELL_KNOWN = IPAddr.new("64:ff9b::/96")
      IPV6_GLOBAL_UNICAST = IPAddr.new("2000::/3")

      # IANA IPv4/IPv6 Special-Purpose Address Registries, updated 2025-10-09.
      # Broad non-global ranges contain a few globally reachable assignments.
      # https://www.iana.org/assignments/iana-ipv4-special-registry/
      # https://www.iana.org/assignments/iana-ipv6-special-registry/
      # https://www.iana.org/assignments/ipv6-address-space/
      GLOBAL_EXCEPTIONS = %w[
        192.0.0.9/32
        192.0.0.10/32
        192.31.196.0/24
        192.52.193.0/24
        192.175.48.0/24
        2001:1::1/128
        2001:1::2/128
        2001:1::3/128
        2001:3::/32
        2001:4:112::/48
        2001:20::/28
        2001:30::/28
        2620:4f:8000::/48
      ].map { |range| IPAddr.new(range) }.freeze

      NON_GLOBAL = %w[
        0.0.0.0/8
        10.0.0.0/8
        100.64.0.0/10
        127.0.0.0/8
        169.254.0.0/16
        172.16.0.0/12
        192.0.0.0/24
        192.0.2.0/24
        192.88.99.0/24
        192.168.0.0/16
        198.18.0.0/15
        198.51.100.0/24
        203.0.113.0/24
        224.0.0.0/4
        240.0.0.0/4
        ::/96
        64:ff9b:1::/48
        100::/64
        100:0:0:1::/64
        2001::/23
        2001:db8::/32
        2002::/16
        3fff::/20
        5f00::/16
        fc00::/7
        fe80::/10
        fec0::/10
        ff00::/8
      ].map { |range| IPAddr.new(range) }.freeze

      module_function

      def target(url, allow_non_public: nil, label: "URL", timeout: 15, lookup: nil)
        targets(url, allow_non_public:, label:, timeout:, lookup:).first
      end

      def targets(url, allow_non_public: nil, label: "URL", timeout: 15, lookup: nil)
        uri, address_resolver = resolver(url, allow_non_public:, label:, timeout:, lookup:)
        address_resolver.call.map { |address| Target.new(uri:, address:) }
      end

      def resolver(url, allow_non_public: nil, label: "URL", timeout: 15, lookup: nil)
        validate_exception(allow_non_public)
        uri = normalize(url, label)
        if uri.scheme == "http" && allow_non_public.nil?
          raise UnsafeURLError, "#{label} must use HTTPS"
        end

        snapshot = uri.to_s.freeze
        resolve_addresses = lambda do
          target = URI(snapshot)
          addresses = resolve(target, label, timeout, lookup: lookup)
          approved_addresses(target, addresses, allow_non_public:, label:)
            .map(&:to_s).freeze
        end
        [URI(snapshot), resolve_addresses]
      end

      def approved_addresses(uri, addresses, allow_non_public: nil, label: "URL")
        validate_exception(allow_non_public)
        if addresses.empty?
          raise UnsafeURLError,
                "#{label} host #{uri.hostname.inspect} resolved to no addresses"
        end
        rejected = addresses.reject do |address|
          policy_uri = URI(uri.to_s).freeze
          policy_address = address.dup.freeze
          globally_reachable?(address) || allow_non_public&.call(policy_uri, policy_address)
        end
        unless rejected.empty?
          raise UnsafeURLError,
                "#{label} host #{uri.hostname.inspect} resolves to a non-public address"
        end
        if uri.scheme == "http" && !addresses.all?(&:loopback?)
          raise UnsafeURLError, "#{label} must use HTTPS"
        end

        addresses
      end

      def approved_address(uri, addresses, allow_non_public: nil, label: "URL")
        approved_addresses(uri, addresses, allow_non_public:, label:).first
      end

      def normalize(url, label = "URL")
        uri = parse(url, label)
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase
        uri.port = nil if uri.port == uri.default_port
        uri.path = "" if uri.path == "/"
        uri
      rescue URI::Error, ArgumentError
        raise UnsafeURLError, "#{label} must be an absolute HTTP(S) URL"
      end

      def redirect_uri(url)
        value = url.to_s
        uri = parse(value, "redirect_uri")
        return value if uri.scheme == "https"

        address = parse_address(uri.hostname)
        return value if uri.hostname.casecmp?("localhost") || address&.loopback?

        raise UnsafeURLError, "redirect_uri must use HTTPS or an explicit loopback address"
      end

      def origin(uri)
        value = uri.dup
        value.path = ""
        value.query = nil
        value.to_s
      end

      def display(uri)
        value = uri.dup
        value.query = nil
        value.to_s
      end

      def globally_reachable?(address)
        address = address.native if address.ipv4_mapped?
        if NAT64_WELL_KNOWN.include?(address)
          embedded = IPAddr.new(address.to_i & 0xffffffff, Socket::AF_INET)
          return globally_reachable?(embedded)
        end
        return true if GLOBAL_EXCEPTIONS.any? { |range| range.include?(address) }
        return false if address.ipv6? && !IPV6_GLOBAL_UNICAST.include?(address)

        NON_GLOBAL.none? { |range| range.include?(address) }
      end

      def resolve(uri, label, timeout, lookup: nil)
        lookup ||= Addrinfo.method(:getaddrinfo)
        entries = lookup.call(uri.hostname, uri.port, nil, :STREAM, timeout: timeout)
        found = entries.filter_map do |entry|
          address = parse_address(entry.ip_address)
          address&.ipv4_mapped? ? address.native : address
        end.uniq
        if found.empty?
          raise UnsafeURLError,
                "#{label} host #{uri.hostname.inspect} resolved to no addresses"
        end

        found
      rescue SocketError, IOError, Timeout::Error
        raise UnsafeURLError, "#{label} host #{uri.hostname.inspect} could not be resolved"
      end

      def parse_address(value)
        IPAddr.new(value)
      rescue IPAddr::Error
        nil
      end

      def validate_exception(exception)
        return if exception.nil? || exception.respond_to?(:call)

        raise ConfigurationError, "allow_non_public: must be callable"
      end

      def parse(url, label)
        uri = URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme) &&
               !uri.hostname.to_s.empty?
          raise UnsafeURLError, "#{label} must be an absolute HTTP(S) URL"
        end
        raise UnsafeURLError, "#{label} must not contain credentials" if uri.user || uri.password
        raise UnsafeURLError, "#{label} must not contain a fragment" if uri.fragment
        raise UnsafeURLError, "#{label} has an invalid port" unless (1..65_535).cover?(uri.port)

        uri
      rescue URI::Error, ArgumentError
        raise UnsafeURLError, "#{label} must be an absolute HTTP(S) URL"
      end
    end
  end
end
