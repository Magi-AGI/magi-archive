# frozen_string_literal: true
#
# The drain's read timeout comes from ATOMSPACE_DRAIN_READ_TIMEOUT, through the real rake task. One /apply is two full
# scans of the Space, over 10 s at dev's corpus size, so the hard-coded 5 s failed events
# (logs/impl5/sidecar_latency.log). STANDALONE: no Decko boot.

require "rake"
require_relative "../../mod/atomspace_mirror/lib/sidecar_client"
require_relative "../../mod/atomspace_mirror/lib/drain_worker"

RSpec.describe "atomspace_mirror:drain read timeout" do
  before(:all) do
    @saved_app = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../mod/atomspace_mirror/lib/tasks/atomspace_mirror.rake", __dir__)
  end

  after(:all) { Rake.application = @saved_app }

  around do |example|
    saved = ENV["ATOMSPACE_DRAIN_READ_TIMEOUT"]
    traps = %w[INT TERM].to_h { |sig| [sig, Signal.trap(sig, "DEFAULT")] }
    example.run
    traps.each { |sig, old| Signal.trap(sig, old) }
    saved ? ENV["ATOMSPACE_DRAIN_READ_TIMEOUT"] = saved : ENV.delete("ATOMSPACE_DRAIN_READ_TIMEOUT")
  end

  def timeout_the_task_uses
    seen = nil
    worker = double("worker", drain_loop: nil, stop: nil)
    allow(DrainWorker).to receive(:new) do |sidecar: :not_passed, **|
      seen = sidecar
      worker
    end
    allow($stdout).to receive(:puts)
    task = Rake::Task["atomspace_mirror:drain"]
    task.reenable
    task.invoke
    # Nothing passed means DrainWorker builds its own default client, with SidecarClient's default.
    (seen == :not_passed ? SidecarClient.new : seen).instance_variable_get(:@read_timeout)
  end

  it "uses the configured value" do
    ENV["ATOMSPACE_DRAIN_READ_TIMEOUT"] = "120"
    expect(timeout_the_task_uses).to eq(120)
  end

  it "keeps SidecarClient's 5 s default when unset" do
    ENV.delete("ATOMSPACE_DRAIN_READ_TIMEOUT")
    expect(timeout_the_task_uses).to eq(5)
  end

  it "keeps the default when set empty" do
    ENV["ATOMSPACE_DRAIN_READ_TIMEOUT"] = ""
    expect(timeout_the_task_uses).to eq(5)
  end

  it "refuses a value that is not a number rather than guessing" do
    ENV["ATOMSPACE_DRAIN_READ_TIMEOUT"] = "soon"
    expect { timeout_the_task_uses }.to raise_error(ArgumentError)
  end
end
