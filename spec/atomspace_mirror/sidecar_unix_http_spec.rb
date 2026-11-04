# frozen_string_literal: true
#
# B-5: the UNIX-socket exchange stays within a deadline against real sockets. STANDALONE: no Decko boot.

require "tmpdir"
require "json"
require_relative "../../mod/atomspace_mirror/lib/sidecar_client"

RSpec.describe SidecarUnixHttp do
  around do |example|
    Dir.mktmpdir("sidecar-ipc") do |dir|
      @path = File.join(dir, "s.sock")
      example.run
    end
  end

  after do
    @threads&.each(&:kill)
    @peers&.each { |peer| peer.close unless peer.closed? }
    @server&.close
  end

  # A peer that accepts, reads the request, then runs the block with the connection.
  def serve(&block)
    @server = UNIXServer.new(@path)
    @peers = []
    @threads = [Thread.new do
      peer = @server.accept
      @peers << peer
      block.call(peer)
    end]
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def answer(peer, body, status: "200 OK")
    peer.readpartial(4096)
    peer.write("HTTP/1.0 #{status}\r\nContent-Type: application/json\r\n\r\n#{body}")
    peer.close
  end

  describe ".exchange" do
    it "round-trips a request, with non-ASCII content intact" do
      received = nil
      serve do |peer|
        received = peer.readpartial(4096)
        peer.write("HTTP/1.0 201 Created\r\n\r\n#{JSON.generate('name' => 'Café')}")
        peer.close
      end
      status, body = described_class.exchange(@path, :post, "/x", JSON.generate("a" => "é"), timeout: 2)
      expect(status).to eq(201)
      expect(JSON.parse(body)).to eq("name" => "Café")
      expect(received).to start_with("POST /x HTTP/1.0\r\n")
    end

    it "times out on a peer that accepts and never responds, and closes its socket" do
      eof = Queue.new
      serve do |peer|
        peer.readpartial(4096)
        eof << (peer.read == "" ? :closed : :data)
      end
      took = elapsed do
        expect { described_class.exchange(@path, :get, "/x", "", timeout: 0.3) }
          .to raise_error(SidecarUnixHttp::DeadlineExceeded)
      end
      expect(took).to be_between(0.25, 2)
      expect(Timeout.timeout(2) { eof.pop }).to eq(:closed)
    end

    it "times out on a listener that never accepts" do
      @server = UNIXServer.new(@path)
      took = elapsed do
        expect { described_class.exchange(@path, :get, "/x", "", timeout: 0.3) }
          .to raise_error(SidecarUnixHttp::DeadlineExceeded)
      end
      expect(took).to be < 2
    end

    it "applies one deadline to the whole exchange, so a slow drip cannot extend it" do
      serve do |peer|
        peer.readpartial(4096)
        loop do
          peer.write("x")
          sleep 0.05
        end
      end
      took = elapsed do
        expect { described_class.exchange(@path, :get, "/x", "", timeout: 0.3) }
          .to raise_error(SidecarUnixHttp::DeadlineExceeded)
      end
      expect(took).to be < 2
    end

    it "times out writing a large request to a peer that never reads" do
      @server = UNIXServer.new(@path)
      took = elapsed do
        expect { described_class.exchange(@path, :post, "/x", "x" * 8_000_000, timeout: 0.3) }
          .to raise_error(SidecarUnixHttp::DeadlineExceeded)
      end
      expect(took).to be < 2
    end

    it "raises the socket's own error when nothing is listening" do
      expect { described_class.exchange(@path, :get, "/x", "", timeout: 1) }.to raise_error(Errno::ENOENT)
      File.write(@path, "")
      expect { described_class.exchange(@path, :get, "/x", "", timeout: 1) }.to raise_error(SystemCallError)
    end
  end

  describe "SidecarClient quarantine" do
    def client(**opts) = SidecarClient.new(socket_path: @path, **opts)

    it "keeps its success path over the real socket" do
      serve { |peer| answer(peer, JSON.generate("card_id" => 7, "removed" => [], "count" => 0, "removed_count" => 0)) }
      expect { client.send(:admin_post, "/admin/quarantine_card_scoped_atoms", { "card_id" => 7 }) }.not_to raise_error
    end

    it "maps a stalled peer to QuarantineError within the deadline" do
      serve { |peer| peer.readpartial(4096); sleep }
      took = elapsed do
        expect { client(admin_timeout: 0.3).quarantine_card_scoped_atoms(7) }
          .to raise_error(SidecarClient::QuarantineError, /transport error.*DeadlineExceeded/)
      end
      expect(took).to be < 2
    end

    it "defaults to a bounded admin deadline" do
      expect(SidecarClient::ADMIN_TIMEOUT_SECONDS).to eq(30)
      expect(client.instance_variable_get(:@admin_timeout)).to eq(30)
    end
  end
end
