# Disposable fixture for the R3 dry runs. Runs only against impl6_r3_capture, a throwaway copy of the local test database.
# Every value here is made up for this test. The password is random and is neither printed nor kept.
require "securerandom"
db = ActiveRecord::Base.connection.current_database
abort "wrong database" unless db == "impl6_r3_capture"
Card::Auth.as_bot do
  Card.create!(name: "Administrator+R3 Fixture Doc", type: "RichText", content: "fixture doc")
  Card.create!(name: "Administrator+R3 Fixture Doc+Child", type: "PlainText", content: "fixture child")
  Card.create!(name: "R3 Fixture Nav", type: "PlainText", content: "fixture nav")
  Card.create!(name: "R3 Fixture User", type_id: Card::UserID,
               subcards: { "+*account" => { "+*email" => "fixture-user@example.invalid", "+*password" => "R3-Fixture-#{SecureRandom.hex(16)}aA1!", "+*status" => "active" } })
  # A role membership, so restore's role path runs too. "Shark" is a role in the seed data.
  Card.fetch("Shark+*members", new: { type: "List" }).add_item!("R3 Fixture User")
end
puts "fixture created: #{Card.where("name like 'R3 Fixture%'").count} named cards"
$stdout.flush
exit!(0)
