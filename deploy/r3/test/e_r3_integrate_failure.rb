# Test only, never delivered. Makes one card's integrate phase raise after its commit, then runs the real restore script,
# to prove a card that committed still reaches the reference map. Runs only against a disposable local database.
Card::Director.prepend(Module.new do
  def integration_phase
    if @card.name.to_s == "Administrator+R3 Fixture Doc"
      puts "mail delivery during the integrate phase: #{Card::Mailer.perform_deliveries}"
      raise "injected integrate failure"
    end
    super
  end
end)
load ENV.fetch("R3_INJECT_SCRIPT")
