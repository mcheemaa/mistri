# frozen_string_literal: true

require "json"
require "openssl"
require "socket"

module Mistri
  module Test
    # A trusted local TLS endpoint that records the hostname presented through
    # SNI and HTTP while the client connects to a pinned loopback address.
    class TlsStubServer
      attr_reader :ca_certificate, :requests, :server_name

      def initialize(hostname:, certificate_hostname: hostname)
        @hostname = hostname
        @certificate_hostname = certificate_hostname
        @requests = []
        @tcp = TCPServer.new("127.0.0.1", 0)
        @ca_certificate, certificate, key = certificates
        context = OpenSSL::SSL::SSLContext.new
        context.cert = certificate
        context.key = key
        context.servername_cb = lambda do |*arguments|
          arguments = arguments.first if arguments.one? && arguments.first.is_a?(Array)
          socket, name = arguments
          @server_name = name || socket.hostname
          nil
        end
        @server = OpenSSL::SSL::SSLServer.new(@tcp, context)
        @thread = Thread.new { serve }
      end

      def origin = "https://#{@hostname}:#{@tcp.addr[1]}"

      def stop
        @tcp.close
        @thread.kill
        @thread.join
      end

      private

      def serve
        loop do
          socket = @server.accept
          request = read_request(socket)
          @requests << request
          payload = JSON.generate("ok" => true)
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
          socket.close
        end
      rescue IOError, OpenSSL::SSL::SSLError
        nil
      end

      def read_request(socket)
        line = socket.gets
        headers = {}
        while (header = socket.gets) && header != "\r\n"
          key, value = header.split(": ", 2)
          headers[key.downcase] = value.to_s.strip
        end
        socket.read(headers["content-length"].to_i)
        { line: line, headers: headers }
      end

      def certificates
        ca_key = OpenSSL::PKey::RSA.new(2048)
        fingerprint = OpenSSL::Digest::SHA256.hexdigest(ca_key.public_key.to_der)[0, 16]
        ca = certificate("Mistri test CA #{fingerprint}", ca_key, serial: 1)
        extension(ca, "basicConstraints", "CA:TRUE", critical: true)
        extension(ca, "keyUsage", "keyCertSign,cRLSign", critical: true)
        ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))

        key = OpenSSL::PKey::RSA.new(2048)
        leaf = certificate(@certificate_hostname, key, serial: 2, issuer: ca.subject)
        extension(leaf, "basicConstraints", "CA:FALSE", critical: true)
        extension(leaf, "keyUsage", "digitalSignature,keyEncipherment", critical: true)
        extension(leaf, "extendedKeyUsage", "serverAuth")
        extension(leaf, "subjectAltName", "DNS:#{@certificate_hostname}")
        leaf.sign(ca_key, OpenSSL::Digest.new("SHA256"))
        [ca, leaf, key]
      end

      def certificate(name, key, serial:, issuer: nil)
        OpenSSL::X509::Certificate.new.tap do |cert|
          cert.version = 2
          cert.serial = serial
          cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
          cert.issuer = issuer || cert.subject
          cert.public_key = key.public_key
          cert.not_before = Time.now - 60
          cert.not_after = Time.now + 3600
        end
      end

      def extension(certificate, name, value, critical: false)
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = certificate
        factory.issuer_certificate = certificate
        certificate.add_extension(factory.create_extension(name, value, critical))
      end
    end
  end
end
