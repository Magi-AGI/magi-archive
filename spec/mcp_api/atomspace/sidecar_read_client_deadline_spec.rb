# frozen_string_literal: true
#
# B-5: the read client stays within a deadline against real sockets. STANDALONE: no Decko boot.

require "tmpdir"
require "json"
require_relative "../../../mod/mcp_api/lib/atomspace/sidecar_read_client"

RSpec.describe Atomspace::SidecarReadClient, "deadline" do
  around do |example|
    Dir.mktmpdir("sidecar-read") do |dir|
      @path = File.join(dir, "s.sock")
      example.run
    end
  end

  after do
    @thread&.kill
    @peer&.close unless @peer&.closed?
    @server&.close
    Atomspace::SidecarReadClient.socket_path = nil
    Atomspace::SidecarReadClient.timeout_seconds = nil
  end

  def serve(&block)
    @server = UNIXServer.new(@path)
    @thread = Thread.new do
      @peer = @server.accept
      block.call(@peer)
    end
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  def answer(peer, body)
    peer.readpartial(4096)
    peer.write("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n#{body}")
    peer.close
  end

  subject(:read_client) { Atomspace::SidecarReadClient.new(account: nil) }

  before do
    Atomspace::SidecarReadClient.socket_path = @path
    Atomspace::SidecarReadClient.timeout_seconds = 0.3
  end

  it "maps a stalled peer to ServiceUnavailable on a read" do
    serve { |peer| peer.readpartial(4096); sleep }
    took = elapsed { expect { read_client.get_card_atom(card_id: 7) }.to raise_error(Atomspace::ServiceUnavailable) }
    expect(took).to be < 2
  end

  it "maps a stalled peer to ServiceUnavailable on the watermark" do
    serve { |peer| peer.readpartial(4096); sleep }
    expect { Atomspace::SidecarReadClient.watermark_meta }.to raise_error(Atomspace::ServiceUnavailable)
  end

  it "keeps its success path over the real socket" do
    serve { |peer| answer(peer, JSON.generate("results" => [])) }
    expect(read_client.get_card_atom(card_id: 7)).to eq([])
  end

  it "takes its deadline from the operator's setting, with a default" do
    Atomspace::SidecarReadClient.timeout_seconds = nil
    expect(Atomspace::SidecarReadClient.timeout_seconds).to eq(10.0)
    saved = ENV["SIDECAR_READ_TIMEOUT_SECONDS"]
    ENV["SIDECAR_READ_TIMEOUT_SECONDS"] = "2.5"
    expect(Atomspace::SidecarReadClient.timeout_seconds).to eq(2.5)
  ensure
    saved ? ENV["SIDECAR_READ_TIMEOUT_SECONDS"] = saved : ENV.delete("SIDECAR_READ_TIMEOUT_SECONDS")
  end
end
