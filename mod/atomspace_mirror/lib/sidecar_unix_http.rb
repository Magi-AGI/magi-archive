# frozen_string_literal: true

require "socket"
require "timeout"

# One HTTP/1.0 exchange with the sidecar over its UNIX socket, finished within a single deadline. The
# sidecar closes the connection after responding, so the response ends at EOF. A peer that accepts and
# then never answers, or answers too slowly, raises DeadlineExceeded instead of holding the caller.
module SidecarUnixHttp
  class DeadlineExceeded < Timeout::Error; end

  CONNECT_RETRY_SECONDS = 0.01

  module_function

  # @return [Array(Integer, String)] the HTTP status (0 if unparseable) and the raw response body
  def exchange(socket_path, verb, path, payload, timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sock = Socket.new(:UNIX, :STREAM)
    connect(sock, socket_path, deadline)
    write_all(sock, request_bytes(verb, path, payload), deadline)
    head, _, body = read_to_eof(sock, deadline).partition("\r\n\r\n")
    [head[%r{\AHTTP/\d\.\d (\d+)}, 1].to_i, body]
  ensure
    sock&.close
  end

  def request_bytes(verb, path, payload)
    "#{verb.to_s.upcase} #{path} HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\n" \
      "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}".b
  end

  def connect(sock, socket_path, deadline)
    address = Socket.sockaddr_un(socket_path)
    begin
      sock.connect_nonblock(address)
    rescue IO::WaitWritable
      # A full listen backlog reports EAGAIN, which select cannot wait on; poll until the deadline.
      remaining!(deadline)
      sleep CONNECT_RETRY_SECONDS
      retry
    rescue Errno::EISCONN
      nil
    end
  end

  def write_all(sock, bytes, deadline)
    offset = 0
    while offset < bytes.bytesize
      written = sock.write_nonblock(bytes.byteslice(offset..), exception: false)
      if written == :wait_writable
        sock.wait_writable(remaining!(deadline))
      else
        offset += written
      end
    end
  end

  def read_to_eof(sock, deadline)
    response = String.new(encoding: Encoding::BINARY)
    loop do
      chunk = sock.read_nonblock(65_536, exception: false)
      case chunk
      when :wait_readable then sock.wait_readable(remaining!(deadline))
      when nil then return response
      else
        response << chunk
        remaining!(deadline)
      end
    end
  end

  def remaining!(deadline)
    left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise DeadlineExceeded, "sidecar did not answer in time" unless left.positive?

    left
  end
end
