# frozen_string_literal: true

namespace :mirror_refresh do
  desc "Refuse a DB refresh unless the mirror is dormant and its tables are absent (SPEC 7.3)"
  task assert_precondition: :environment do
    MirrorRuntimeGuards.assert_refresh_precondition!
    puts "mirror refresh precondition holds"
  end
end
